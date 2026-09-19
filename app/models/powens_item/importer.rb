# Imports Powens accounts and transactions for a single PowensItem connection.
# Fetches account snapshots and per-account transaction history from the Powens
# provider, persisting raw snapshots and returning aggregate import statistics.
class PowensItem::Importer
  attr_reader :powens_item, :powens_provider

  # Build an importer for the given +powens_item+ using the supplied +powens_provider+ client.
  def initialize(powens_item, powens_provider:)
    @powens_item = powens_item
    @powens_provider = powens_provider
  end

  # Run the full import (accounts then transactions) and return a result hash
  # of success flag and per-entity counts. On a failed accounts fetch, returns
  # a +failed_result+ with the same shape and zeroed counts.
  def import
    Rails.logger.info "PowensItem::Importer - Starting import for item #{powens_item.id}"

    accounts_data = fetch_accounts_data
    return failed_result("Failed to fetch accounts data") unless accounts_data

    powens_item.upsert_powens_snapshot!(accounts_data)
    refresh_connection_state

    account_stats = import_accounts(accounts_data)
    transaction_stats = import_transactions

    Rails.logger.info(
      "PowensItem::Importer - Completed import for item #{powens_item.id}: " \
      "#{account_stats[:updated]} accounts updated, #{account_stats[:created]} new accounts discovered, " \
      "#{transaction_stats[:imported]} transactions"
    )

    {
      success: account_stats[:failed].zero? && transaction_stats[:failed].zero?,
      accounts_updated: account_stats[:updated],
      accounts_created: account_stats[:created],
      accounts_failed: account_stats[:failed],
      transactions_imported: transaction_stats[:imported],
      transactions_failed: transaction_stats[:failed]
    }
  end

  private

    # Record the connection state Powens reports (nil when the last sync
    # succeeded), the stalled source, and the earliest consent expiry, so
    # settings can prompt a re-authorization before data goes stale. A
    # connection aggregates sources (openapi, directaccess, ...) that fail
    # independently. Never fails the import.
    def refresh_connection_state
      connections = powens_provider.get_connections
      stalled = connections.find { |connection| connection.with_indifferent_access[:state].present? }
      state = stalled&.with_indifferent_access&.[](:state)
      source_name, access_expires_at = connection_source_details(connections, stalled)

      powens_item.update!(
        connection_state: state,
        connection_state_source: state.present? ? source_name : nil,
        access_expires_at: access_expires_at,
        status: state.present? ? "requires_update" : "good"
      )
    rescue => e
      Rails.logger.warn "PowensItem::Importer - Could not read connection state: #{e.class} - #{e.message}"
    end

    # Name of the source reporting a state, plus the earliest access expiry
    # across every source of the item's connections.
    def connection_source_details(connections, stalled)
      stalled_connection_id = stalled&.with_indifferent_access&.[](:id)
      source_name = nil
      expiries = []

      connections.each do |connection|
        connection_id = connection.with_indifferent_access[:id]
        sources = powens_provider.get_connection_sources(connection_id).map(&:with_indifferent_access)

        expiries.concat(sources.filter_map { |source| source[:access_expire].presence })
        if connection_id == stalled_connection_id
          source_name = sources.find { |source| source[:state].present? }&.[](:name)
        end
      end

      [ source_name, earliest_date(expiries) ]
    end

    # Strictest (earliest) date in the list, or nil when none parses.
    def earliest_date(values)
      earliest = values.compact.min
      return nil if earliest.blank?

      Date.parse(earliest.to_s)
    rescue ArgumentError
      nil
    end

    # Fetch the current account list from Powens, returning a hash of +items+ or
    # +nil+ on any provider/parse error (which is logged and captured).
    def fetch_accounts_data
      items = powens_provider.get_accounts
      { items: items }
    rescue Provider::Powens::PowensError => e
      mark_requires_update! if e.error_type.in?([ :unauthorized, :access_forbidden ])
      Rails.logger.error "PowensItem::Importer - Powens API error: #{e.error_type}"
      capture_sync_error("Failed to fetch accounts data", e, error_type: e.error_type)
      nil
    rescue JSON::ParserError => e
      Rails.logger.error "PowensItem::Importer - Failed to parse Powens API response: #{e.class}"
      capture_sync_error("Failed to parse Powens accounts response", e)
      nil
    rescue => e
      Rails.logger.error "PowensItem::Importer - Unexpected error fetching accounts: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      capture_sync_error("Unexpected error fetching accounts", e)
      nil
    end

    # Upsert snapshots for linked accounts and record newly discovered ones,
    # returning a stats hash of +updated+, +created+, and +failed+ counts.
    def import_accounts(accounts_data)
      stats = { updated: 0, created: 0, failed: 0 }
      accounts = Array(accounts_data[:items])
      linked_account_ids = powens_item.powens_accounts.joins(:account_provider).pluck(:account_id).map(&:to_s)
      all_existing_ids = powens_item.powens_accounts.pluck(:account_id).map(&:to_s)
      linked_identities = powens_item.powens_accounts
                                      .joins(:account_provider)
                                      .filter_map { |account| account_identity(account.raw_payload) }

      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:id].presence
        next if account_id.blank?
        next if account[:original_name].blank? && account[:name].blank?
        # Deleted accounts (Powens soft-deletion) are excluded from imports.
        next if account[:deleted].present?

        if linked_account_ids.include?(account_id.to_s)
          import_account(account)
          stats[:updated] += 1
        elsif !all_existing_ids.include?(account_id.to_s)
          powens_account = powens_item.powens_accounts.build(account_id: account_id.to_s)
          powens_account.upsert_powens_snapshot!(account)
          # Re-authorizing a bank at Powens creates a second connection that
          # returns the same bank accounts under new ids. Keep those out of
          # setup so the user never links one bank account twice; the linked
          # original keeps feeding the Sure account.
          if linked_identities.include?(account_identity(account))
            powens_account.update!(ignored: true)
            Rails.logger.info "PowensItem::Importer - Ignoring duplicate discovery of account #{account_id} (already linked)"
          end
          stats[:created] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "PowensItem::Importer - Failed to import account #{account_id}: #{e.message}"
      end

      stats
    end

    # Upsert the snapshot for a single already-linked Powens account.
    def import_account(account_data)
      account = account_data.with_indifferent_access
      powens_account = powens_item.powens_accounts.find_by(account_id: account[:id].to_s)
      return unless powens_account

      powens_account.upsert_powens_snapshot!(account)
    end

    # Fetch and store transactions for every visible linked account, returning
    # a stats hash of +imported+ and +failed+ counts.
    def import_transactions
      stats = { imported: 0, failed: 0 }

      powens_item.powens_accounts.joins(:account).merge(Account.visible).each do |powens_account|
        result = fetch_and_store_transactions(powens_account)
        if result[:success]
          stats[:imported] += result[:transactions_count]
        else
          stats[:failed] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "PowensItem::Importer - Failed to fetch/store transactions for Powens account #{powens_account.id}: #{e.class}"
      end

      stats
    end

    # Fetch transactions for +powens_account+ since its sync start date and persist
    # them, returning a result hash with +success+ and +transactions_count+.
    def fetch_and_store_transactions(powens_account)
      start_date = determine_sync_start_date(powens_account)
      Rails.logger.info "PowensItem::Importer - Fetching transactions for Powens account #{powens_account.id} since #{start_date}"

      transactions = powens_provider.get_account_transactions(
        account_id: powens_account.account_id,
        since: start_date
      )

      store_transactions(powens_account, fresh_transactions: Array(transactions))

      { success: true, transactions_count: Array(transactions).count }
    rescue Provider::Powens::PowensError => e
      mark_requires_update! if e.error_type.in?([ :unauthorized, :access_forbidden ])
      Rails.logger.error "PowensItem::Importer - Powens API error for account #{powens_account.id}: #{e.error_type}"
      capture_sync_error("Failed to fetch transactions", e, powens_account: powens_account, error_type: e.error_type)
      { success: false, transactions_count: 0, error: I18n.t("powens_item.errors.transactions_failed") }
    rescue JSON::ParserError => e
      Rails.logger.error "PowensItem::Importer - Failed to parse transaction response for account #{powens_account.id}: #{e.class}"
      capture_sync_error("Failed to parse Powens transactions response", e, powens_account: powens_account)
      { success: false, transactions_count: 0, error: "Failed to parse response" }
    rescue => e
      Rails.logger.error "PowensItem::Importer - Unexpected error fetching transactions for account #{powens_account.id}: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      capture_sync_error("Unexpected error fetching transactions", e, powens_account: powens_account)
      { success: false, transactions_count: 0, error: I18n.t("powens_item.errors.transactions_failed") }
    end

    # Powens transactions keep a stable id across the coming→posted lifecycle
    # (the `coming` flag flips), so deduplication is a plain merge by id.
    def store_transactions(powens_account, fresh_transactions:)
      existing = powens_account.raw_transactions_payload.to_a

      by_id = {}
      existing.each do |tx|
        key = transaction_id(tx)
        by_id[key] = tx if key.present?
      end
      fresh_transactions.each do |tx|
        next unless tx.is_a?(Hash)

        key = transaction_id(tx)
        by_id[key] = tx if key.present?
      end

      final_transactions = by_id.values

      if final_transactions != existing
        Rails.logger.info(
          "PowensItem::Importer - Storing #{final_transactions.count} transactions " \
          "(#{existing.count} existing) for account #{powens_account.account_id}"
        )
        powens_account.upsert_powens_transactions_snapshot!(final_transactions)
      else
        Rails.logger.info "PowensItem::Importer - No transaction changes for account #{powens_account.account_id}"
      end
    end

    # Extract the Powens transaction id from a raw transaction hash, or +nil+.
    def transaction_id(transaction)
      data = transaction.with_indifferent_access
      data[:id].presence
    end

    # Bank-side identity of an account: IBAN when the connector exposes it,
    # otherwise the bank account number. Two Powens connections to the same
    # bank return the same identity for the same underlying account.
    def account_identity(snapshot)
      return nil if snapshot.blank?

      data = snapshot.with_indifferent_access
      data[:iban].presence || data[:number].presence
    end

    # Resolve the date from which to fetch transactions for +powens_account+,
    # preferring explicit per-account/item start dates, then a recent window for
    # incremental syncs. On the very first import (no stored transactions yet)
    # request the full available history: Powens guarantees at least 3 months
    # and often exposes several years (see first_date in list responses).
    def determine_sync_start_date(powens_account)
      return powens_account.sync_start_date if powens_account.sync_start_date.present?
      return powens_item.sync_start_date if powens_item.sync_start_date.present?

      has_stored_transactions = powens_account.raw_transactions_payload.to_a.any?
      if has_stored_transactions && powens_item.last_synced_at
        powens_item.last_synced_at - 7.days
      else
        FULL_HISTORY_START
      end
    end

    # Far-past date used as an explicit min_date on the first import so Powens
    # returns every transaction it holds (down to the connector's first_date).
    FULL_HISTORY_START = Date.new(1900, 1, 1).freeze

    # Record a provider sync error as a DebugLogEntry with structured metadata.
    def capture_sync_error(message, error, powens_account: nil, error_type: nil)
      metadata = { powens_item_id: powens_item.id, error_class: error.class.name, error_message: error.message }
      metadata[:powens_account_id] = powens_account.id if powens_account
      metadata[:error_type] = error_type if error_type

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: message,
        source: self.class.name,
        provider_key: "powens",
        family: powens_item.family,
        account_provider: powens_account&.account_provider,
        metadata: metadata
      )
    end

    # Flag the item as requiring re-authorization, swallowing update errors.
    def mark_requires_update!
      powens_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "PowensItem::Importer - Failed to update item status: #{e.message}"
    end

    # Build a failure result mirroring +import+'s shape with zeroed counts.
    def failed_result(error)
      {
        success: false,
        error: error,
        accounts_updated: 0,
        accounts_created: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0
      }
    end
end
