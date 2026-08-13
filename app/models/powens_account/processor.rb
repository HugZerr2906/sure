class PowensAccount::Processor
  include CurrencyNormalizable

  SanitizedProcessingError = Class.new(StandardError)

  attr_reader :powens_account

  # Build a processor for the given +powens_account+.
  def initialize(powens_account)
    @powens_account = powens_account
  end

  # Sync the linked account's balance and process its transactions. No-op when
  # the Powens account isn't linked to a Sure account.
  def process
    unless powens_account.current_account.present?
      Rails.logger.info "PowensAccount::Processor - No linked account for powens_account #{powens_account.id}, skipping processing"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "PowensAccount::Processor - Failed to process account powens_account_id=#{powens_account.id} error_class=#{e.class.name}"
    report_exception(e, "account")
    raise
  end

  private

    # Update the linked Sure account's balance/currency from the Powens snapshot.
    def process_account!
      account = powens_account.current_account
      balance = powens_account.current_balance || 0

      # Loan balances are stored as positive debt in Sure regardless of Powens' sign.
      balance = balance.abs if account.accountable_type == "Loan"
      currency = parse_currency(powens_account.currency) || account.currency || "EUR"

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    # Delegate to the transactions processor, capturing and logging failures.
    def process_transactions
      PowensAccount::Transactions::Processor.new(powens_account).process
    rescue => e
      report_exception(e, "transactions")
      Rails.logger.error "PowensAccount::Processor - Failed to process transactions powens_account_id=#{powens_account.id} error_class=#{e.class.name}"
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process transactions",
        source: self.class.name,
        provider_key: "powens",
        family: powens_account.powens_item.family,
        account_provider: powens_account.account_provider,
        metadata: { powens_account_id: powens_account.id, error_class: e.class.name, error_message: e.message }
      )
      { success: false, failed: 1, errors: [ { error: I18n.t("powens_item.errors.account_processing_failed") } ] }
    end

    # Report a processing error to Sentry with a sanitized message and tags.
    def report_exception(error, context)
      safe_error = SanitizedProcessingError.new("Powens account processing failed")

      Sentry.capture_exception(safe_error) do |scope|
        scope.set_tags(
          powens_account_id: powens_account.id,
          context: context,
          error_class: error.class.name
        )
        scope.set_context(
          "powens_account_processor",
          {
            powens_account_id: powens_account.id,
            context: context,
            error_class: error.class.name
          }
        )
      end
    end

    # CurrencyNormalizable hook: warn when a Powens currency code is unrecognized.
    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Powens account #{powens_account.id}, falling back to account currency")
    end
end
