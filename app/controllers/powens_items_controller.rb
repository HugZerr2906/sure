class PowensItemsController < ApplicationController
  before_action :set_powens_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [
    :new, :create, :preload_accounts, :select_accounts, :link_accounts,
    :select_existing_account, :link_existing_account, :edit, :update,
    :destroy, :sync, :setup_accounts, :complete_account_setup
  ]

  # List the family's active Powens connections in settings.
  def index
    @powens_items = Current.family.powens_items.active.ordered
    render layout: "settings"
  end

  # Show a single Powens connection.
  def show
  end

  # Render the new-connection form.
  def new
    @powens_item = Current.family.powens_items.build
  end

  # Render the edit-connection form.
  def edit
  end

  # Create a Powens connection and kick off its first sync.
  def create
    @powens_item = Current.family.powens_items.build(powens_item_params)
    @powens_item.name = t("powens_items.provider_panel.default_connection_name") if @powens_item.name.blank?

    if @powens_item.save
      @powens_item.sync_later
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@powens_item.errors.full_messages.join(", "))
    end
  end

  # Update connection settings (name/domain/token/start date).
  def update
    if @powens_item.update(update_params)
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@powens_item.errors.full_messages.join(", "))
    end
  end

  # Unlink all accounts then schedule deletion of the connection.
  def destroy
    results = @powens_item.unlink_all!(dry_run: false)

    if results.any? { |result| result[:error].present? }
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Powens unlink during destroy failed",
        source: self.class.name,
        provider_key: "powens",
        family: @powens_item.family,
        metadata: { powens_item_id: @powens_item.id, failures: results.select { |r| r[:error].present? } }
      )
      redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
      return
    end

    @powens_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "warn",
      message: "Powens unlink during destroy failed",
      source: self.class.name,
      provider_key: "powens",
      family: @powens_item&.family,
      metadata: { powens_item_id: @powens_item&.id, error_class: e.class.name, error_message: e.message }
    )
    redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
  end

  # Trigger a manual sync unless one is already running.
  def sync
    @powens_item.sync_later unless @powens_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Fetch accounts from the API (JSON) so the UI can show whether any exist.
  def preload_accounts
    powens_item = requested_powens_item
    return render json: { success: false, error: "no_credentials", has_accounts: false } unless powens_item.credentials_configured?

    error = fetch_powens_accounts_from_api(powens_item)
    render json: { success: error.blank?, error_message: error, has_accounts: powens_item.powens_accounts.exists? }
  end

  # Render the picker of unlinked Powens accounts for a new Sure account.
  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    @powens_item = requested_powens_item

    unless @powens_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @api_error = fetch_powens_accounts_from_api(@powens_item)
    @powens_accounts = @powens_item.powens_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)

    render layout: false
  end

  # Create new Sure accounts for the selected Powens accounts and link them.
  def link_accounts
    powens_item = requested_powens_item
    unless powens_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    selected_ids = Array(params[:account_ids]).compact_blank
    if selected_ids.empty?
      redirect_to select_accounts_powens_items_path(powens_item_id: powens_item.id, accountable_type: params[:accountable_type], return_to: safe_return_to_path), alert: t(".no_accounts_selected")
      return
    end

    account_type = params[:accountable_type].presence || "Depository"
    unless Provider::PowensAdapter.supported_account_types.include?(account_type)
      redirect_to new_account_path, alert: t(".unsupported_account_type")
      return
    end

    created_accounts = []

    ActiveRecord::Base.transaction do
      powens_item.powens_accounts.where(id: selected_ids).find_each do |powens_account|
        next if powens_account.account_provider.present?

        activate_powens_account(powens_item, powens_account)
        account = create_account_from_powens(powens_account, account_type)
        AccountProvider.create!(account: account, provider: powens_account)
        created_accounts << account
      end
    end

    powens_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to safe_return_to_path || accounts_path, notice: t(".success", count: created_accounts.count)
    else
      redirect_to select_accounts_powens_items_path(powens_item_id: powens_item.id, accountable_type: account_type, return_to: safe_return_to_path), alert: t(".link_failed")
    end
  end

  # Render the picker to attach a Powens account to an existing Sure account.
  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    @powens_item = requested_powens_item
    unless @powens_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @api_error = fetch_powens_accounts_from_api(@powens_item)
    @powens_accounts = @powens_item.powens_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
    @return_to = safe_return_to_path

    render layout: false
  end

  # Link a selected Powens account to an existing Sure account and sync.
  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    powens_item = requested_powens_item

    unless powens_item.credentials_configured?
      redirect_to settings_providers_path, alert: t("powens_items.select_existing_account.no_credentials_configured")
      return
    end

    if params[:powens_account_id].blank?
      redirect_to accounts_path, alert: t(".no_account_selected")
      return
    end

    powens_account = powens_item.powens_accounts.find_by(id: params[:powens_account_id])
    unless powens_account
      redirect_to accounts_path, alert: t(".no_account_selected")
      return
    end

    if account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    if powens_account.account_provider.present?
      redirect_to accounts_path, alert: t(".powens_account_already_linked")
      return
    end

    activate_powens_account(powens_item, powens_account)
    AccountProvider.create!(account: account, provider: powens_account)
    powens_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name)
  end

  # Render the post-sync setup screen for accounts still needing a decision.
  def setup_accounts
    @api_error = fetch_powens_accounts_from_api(@powens_item)
    @powens_accounts = @powens_item.powens_accounts.needs_setup.order(:name)
    @account_type_options = [
      [ t(".account_types.skip"), "skip" ],
      [ t(".account_types.depository"), "Depository" ],
      [ t(".account_types.loan"), "Loan" ],
      [ t(".account_types.investment"), "Investment" ]
    ]
    @powens_account_type_suggestions = @powens_accounts.each_with_object({}) do |powens_account, suggestions|
      suggestions[powens_account.id] = powens_account.suggested_account_type || "skip"
    end
  end

  # Apply the user's per-account setup choices (create/link or skip).
  def complete_account_setup
    account_types = params[:account_types] || {}
    created_accounts = []
    skipped_count = 0

    ActiveRecord::Base.transaction do
      account_types.each do |powens_account_id, selected_type|
        powens_account = @powens_item.powens_accounts.find_by(id: powens_account_id)
        next unless powens_account

        if selected_type.blank? || selected_type == "skip"
          # Persist the skip so the account stops resurfacing as "needs setup" on every sync.
          powens_account.update!(ignored: true) unless powens_account.account_provider.present?
          skipped_count += 1
          next
        end

        next unless Provider::PowensAdapter.supported_account_types.include?(selected_type)
        next if powens_account.account_provider.present?

        activate_powens_account(@powens_item, powens_account)
        account = create_account_from_powens(powens_account, selected_type)
        AccountProvider.create!(account: account, provider: powens_account)
        created_accounts << account
      end
    end

    @powens_item.sync_later if created_accounts.any?

    flash[:notice] = if created_accounts.any?
      t(".success", count: created_accounts.count)
    elsif skipped_count.positive?
      t(".all_skipped")
    else
      t(".no_accounts")
    end

    redirect_to accounts_path, status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Powens account setup failed",
      source: self.class.name,
      provider_key: "powens",
      family: @powens_item&.family,
      metadata: { powens_item_id: @powens_item&.id, error_class: e.class.name, error_message: e.message }
    )
    redirect_to accounts_path, alert: t(".creation_failed"), status: :see_other
  end

  private

    # Load the requested item scoped to the current family.
    def set_powens_item
      @powens_item = Current.family.powens_items.find(params[:id])
    end

    # Strong params for creating/updating a connection.
    def powens_item_params
      params.require(:powens_item).permit(:name, :sync_start_date, :domain, :access_token)
    end

    # Params for update, dropping a blank token so it isn't overwritten.
    def update_params
      permitted = powens_item_params
      permitted = permitted.except(:access_token) if permitted[:access_token].blank?
      permitted
    end

    # Load the active item referenced by powens_item_id, scoped to the family.
    def requested_powens_item
      Current.family.powens_items.active.find_by!(id: params[:powens_item_id])
    end

    # Enable the Powens account if it is still disabled (PSU consent) — best
    # effort: linking should not fail because the activation call fails.
    def activate_powens_account(powens_item, powens_account)
      return unless powens_account.needs_activation?

      provider = powens_item.powens_provider
      return unless provider

      provider.enable_account(powens_account.account_id)
      powens_account.update!(disabled: false, account_status: "active")
    rescue Provider::Powens::PowensError => e
      Rails.logger.warn "PowensItemsController - Failed to enable account #{powens_account.account_id}: #{e.message}"
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Failed to enable Powens account",
        source: self.class.name,
        provider_key: "powens",
        family: powens_item.family,
        metadata: { powens_item_id: powens_item.id, powens_account_id: powens_account.id, error_class: e.class.name, error_message: e.message }
      )
    end

    # Fetch and upsert account snapshots from the API; returns an error string or nil.
    def fetch_powens_accounts_from_api(powens_item)
      return t("powens_items.setup_accounts.no_credentials") unless powens_item.credentials_configured?

      provider = powens_item.powens_provider
      accounts = provider.get_accounts
      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:id].presence
        next if account_id.blank?
        next if account[:original_name].blank? && account[:name].blank?
        next if account[:deleted].present?

        powens_account = powens_item.powens_accounts.find_or_initialize_by(account_id: account_id.to_s)
        powens_account.upsert_powens_snapshot!(account)
      end

      nil
    rescue Provider::Powens::PowensError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Powens API error while fetching accounts",
        source: self.class.name,
        provider_key: "powens",
        family: powens_item.family,
        metadata: { powens_item_id: powens_item.id, error_class: e.class.name, error_message: e.message }
      )
      t("powens_items.setup_accounts.api_error")
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Unexpected error fetching Powens accounts",
        source: self.class.name,
        provider_key: "powens",
        family: powens_item.family,
        metadata: { powens_item_id: powens_item.id, error_class: e.class.name, error_message: e.message }
      )
      t("powens_items.setup_accounts.api_error")
    end

    # Create and sync a Sure account from a Powens account snapshot.
    def create_account_from_powens(powens_account, account_type)
      # Linking an account clears any prior skip so a future unlink re-prompts for setup.
      powens_account.update!(ignored: false) if powens_account.ignored?

      balance = powens_account.current_balance || 0
      balance = balance.abs if account_type == "Loan"
      subtype = if powens_account.suggested_account_type == account_type
        powens_account.suggested_subtype
      end

      Account.create_and_sync(
        {
          family: Current.family,
          name: powens_account.name,
          balance: balance,
          cash_balance: balance,
          currency: powens_account.currency || "EUR",
          accountable_type: account_type,
          accountable_attributes: subtype.present? ? { subtype: subtype } : {}
        },
        skip_initial_sync: true
      )
    end

    # Re-render the providers settings panel (Turbo) or redirect with a flash.
    def render_provider_panel(flash_type, message)
      if turbo_frame_request?
        flash.now[flash_type] = message
        @powens_items = Current.family.powens_items.active.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "powens-providers-panel",
            partial: "settings/providers/powens_panel",
            locals: { powens_items: @powens_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, { flash_type => message, status: :see_other }
      end
    end

    # Re-render the providers panel with an error (Turbo) or redirect with alert.
    def render_provider_panel_error(message)
      @error_message = message
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "powens-providers-panel",
          partial: "settings/providers/powens_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end

    # Validate the return_to param as a safe in-app relative path, or nil.
    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s.strip
      return nil unless return_to.start_with?("/")
      return nil if return_to[1] == "/" || return_to[1] == "\\"
      return nil if return_to.include?("\\") || return_to.match?(/[[:cntrl:]]/)
      return nil if encoded_path_separator?(return_to)

      uri = URI.parse(return_to)
      return nil unless uri.relative?

      Rails.application.routes.recognize_path(uri.path, method: :get)

      return_to
    rescue URI::InvalidURIError, ActionController::RoutingError
      nil
    end

    # True if the path's second char is a percent-encoded slash/backslash
    # (used to block protocol-relative redirect bypasses).
    def encoded_path_separator?(return_to)
      encoded_second_character = return_to[1, 3]
      return false unless encoded_second_character&.start_with?("%")

      decoded = URI.decode_www_form_component(encoded_second_character)
      decoded == "/" || decoded == "\\"
    rescue ArgumentError
      true
    end
end
