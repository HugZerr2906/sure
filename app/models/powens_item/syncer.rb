class PowensItem::Syncer
  include SyncStats::Collector

  SafeSyncError = Class.new(StandardError)

  # Error carrying the structured per-stage sync errors for health reporting.
  class SyncError < StandardError
    attr_reader :sync_errors

    # Build the error with a +message+ and the collected +sync_errors+.
    def initialize(message, sync_errors:)
      super(message)
      @sync_errors = sync_errors
    end
  end

  attr_reader :powens_item

  # Build a syncer for the given +powens_item+.
  def initialize(powens_item)
    @powens_item = powens_item
  end

  # Run the full sync: import, account setup detection, transaction processing,
  # balance sync scheduling, and stats/health collection. Raises on failures.
  def perform_sync(sync)
    sync.update!(status_text: "Importing accounts from Powens...") if sync.respond_to?(:status_text)
    import_result = powens_item.import_latest_powens_data
    raise_if_failed_result!(import_result, stage: "Powens import")

    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: powens_item.powens_accounts)

    linked_accounts = powens_item.powens_accounts.joins(:account_provider)
    unlinked_accounts = powens_item.powens_accounts.needs_setup

    if unlinked_accounts.any?
      powens_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      powens_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      mark_import_started(sync)
      process_results = powens_item.process_accounts
      raise_if_failed_results!(process_results, stage: "Powens account processing")

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      schedule_results = powens_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      raise_if_failed_results!(schedule_results, stage: "Powens account sync scheduling")

      account_ids = linked_accounts.includes(:account_provider).filter_map { |pa| pa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "powens")
    else
      Rails.logger.info "PowensItem::Syncer - No linked accounts to process"
    end

    collect_health_stats(sync, errors: nil)
  rescue SyncError => e
    collect_health_stats(sync, errors: e.sync_errors)
    raise
  rescue => e
    safe_message = I18n.t("powens_item.errors.sync_failed")
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Unexpected sync error",
      source: self.class.name,
      provider_key: "powens",
      family: powens_item.family,
      metadata: { powens_item_id: powens_item.id, error_class: e.class.name, error_message: e.message }
    )
    collect_health_stats(sync, errors: [ { message: safe_message, category: "sync_error" } ])
    raise SafeSyncError.new(safe_message), cause: nil
  end

  # Post-sync hook (no work required for Powens).
  def perform_post_sync
    # no-op
  end

  private

    # Raise a SyncError if a single result hash indicates failure.
    def raise_if_failed_result!(result, stage:)
      return unless failed_result?(result)

      errors = errors_from_result(result, stage: stage)
      raise SyncError.new(error_message(stage, errors), sync_errors: errors)
    end

    # Raise a SyncError if any result in the collection indicates failure.
    def raise_if_failed_results!(results, stage:)
      errors = Array(results).filter_map do |result|
        next unless failed_result?(result)

        errors_from_result(result, stage: stage).first
      end

      return if errors.empty?

      raise SyncError.new(error_message(stage, errors), sync_errors: errors)
    end

    # True when +result+ is a hash explicitly flagged success: false.
    def failed_result?(result)
      result.is_a?(Hash) && result.with_indifferent_access[:success] == false
    end

    # Normalize a failed result into an array of { message:, category: } errors.
    def errors_from_result(result, stage:)
      data = result.with_indifferent_access
      messages = []
      messages << data[:error] if data[:error].present?
      Array(data[:errors]).each do |entry|
        messages << entry[:error] if entry.is_a?(Hash) && entry[:error].present?
      end
      messages.map { |m| { message: m, category: stage } }
    end

    def error_message(stage, errors)
      "#{stage} failed: #{errors.map { |e| e[:message] }.join('; ')}"
    end
end
