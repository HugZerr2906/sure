require "digest/md5"

class PowensEntry::Processor
  include CurrencyNormalizable

  # Stable external id for a transaction: its Powens id.
  def self.canonical_external_id(powens_transaction)
    data = powens_transaction.with_indifferent_access
    "powens_#{data[:id]}"
  end

  # Powens marks not-yet-posted transactions with coming: true.
  def self.pending?(powens_transaction)
    data = powens_transaction.with_indifferent_access
    data[:coming] == true
  end

  # Build a processor for a single raw Powens transaction tied to +powens_account+.
  def initialize(powens_transaction, powens_account:)
    @powens_transaction = powens_transaction
    @powens_account = powens_account
  end

  # Import the transaction into the linked Sure account via the import adapter.
  # Returns nil when the account isn't linked; re-raises on validation/save errors.
  def process
    unless account.present?
      Rails.logger.warn "PowensEntry::Processor - No linked account for powens_account #{powens_account.id}, skipping transaction #{external_id}"
      return nil
    end

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "powens",
      merchant: merchant,
      notes: notes,
      extra: extra_metadata
    )
  rescue ArgumentError => e
    Rails.logger.error "PowensEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error "PowensEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
    raise StandardError.new("Failed to import transaction: #{e.message}")
  rescue => e
    Rails.logger.error "PowensEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise StandardError.new("Unexpected error importing transaction: #{e.message}")
  end

  private

    attr_reader :powens_transaction, :powens_account

    # Memoized adapter that writes provider transactions into the Sure account.
    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # The linked Sure account for this transaction, if any.
    def account
      @account ||= powens_account.current_account
    end

    # The raw transaction as an indifferent-access hash.
    def data
      @data ||= powens_transaction.with_indifferent_access
    end

    # Canonical external id for this transaction (see .canonical_external_id).
    def external_id
      @external_id ||= self.class.canonical_external_id(data)
    end

    # Display name: the full bank wording, then the editable wording.
    def name
      data[:original_wording].presence || data[:wording].presence || I18n.t("transactions.unknown_name")
    end

    # Powens amounts use banking convention: negative is money out, positive is
    # money in. Sure stores expenses as positive and income as negative, so the
    # sign is flipped (same convention as the Up processor).
    #
    # NOTE: this convention must be confirmed against a real Powens payload on
    # the first sync — if Crédit Mutuel ever reports expenses as positive this
    # single sign flip is where it needs to change.
    def amount
      raw_value = data[:value]
      parsed_amount = case raw_value
      when String
        BigDecimal(raw_value)
      when Numeric
        BigDecimal(raw_value.to_s)
      else
        BigDecimal("0")
      end

      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Powens transaction amount: #{e.class}"
      raise ArgumentError, "Invalid transaction amount"
    end

    # Transaction currency: Powens transactions carry no currency of their own
    # (only original_currency for FX), so the account currency is used.
    def currency
      parse_currency(powens_account.currency) || account&.currency || "EUR"
    end

    # Posted date (or application date as a fallback) as a Date.
    def date
      value = data[:date].presence || data[:application_date].presence
      case value
      when String
        if value.include?("T") || value.include?(":")
          Time.parse(value).in_time_zone(account&.family&.timezone).to_date
        else
          Date.parse(value)
        end
      when Time, DateTime
        value.in_time_zone(account&.family&.timezone).to_date
      when Date
        value
      else
        Rails.logger.error("Powens transaction has no usable date value")
        raise ArgumentError, "Invalid date format"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Powens transaction date: #{e.class}")
      raise ArgumentError, "Unable to parse transaction date"
    end

    # Optional user-entered comment attached to the transaction.
    def notes
      data[:comment].presence
    end

    # Find or create the merchant for this transaction's wording, or nil.
    def merchant
      merchant_name = name.to_s.strip.presence
      return nil unless merchant_name

      provider_merchant_id = "powens_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}"

      @merchant ||= import_adapter.find_or_create_merchant(
        provider_merchant_id: provider_merchant_id,
        name: merchant_name,
        source: "powens"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "PowensEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
      nil
    end

    # Provider metadata persisted on Transaction#extra (pending/type/wording).
    def extra_metadata
      {
        "powens" => {
          "pending" => pending?,
          "transaction_type" => data[:type],
          "original_wording" => data[:original_wording],
          "coming" => data[:coming],
          "id_account" => data[:id_account]
        }.compact
      }
    end

    # Whether this transaction is still coming (unposted) on Powens.
    def pending?
      self.class.pending?(data)
    end

    # CurrencyNormalizable hook: warn when a Powens currency code is unrecognized.
    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in Powens transaction #{external_id}, falling back to account currency")
    end
end
