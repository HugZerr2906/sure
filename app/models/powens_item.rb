class PowensItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  # Same host pattern as the API client (biapi.pro tenants only).
  DOMAIN_PATTERN = Provider::Powens::DOMAIN_PATTERN

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :access_token, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :powens_accounts, dependent: :destroy
  has_many :accounts, through: :powens_accounts

  validates :name, presence: true
  validates :domain, presence: true, on: :create
  validates :domain, format: { with: DOMAIN_PATTERN, message: I18n.t("powens_item.errors.invalid_domain") }, allow_blank: true
  validates :access_token, presence: true, on: :create

  before_validation :normalize_domain

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  # Mark the item for deletion and enqueue the background destroy job.
  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  # Run the importer to fetch the latest accounts/transactions from Powens.
  def import_latest_powens_data
    provider = powens_provider
    unless provider
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Cannot import: Powens provider is not configured",
        source: self.class.name,
        provider_key: "powens",
        family: family,
        metadata: { powens_item_id: id }
      )
      raise StandardError.new("Powens provider is not configured")
    end

    PowensItem::Importer.new(self, powens_provider: provider).import
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Failed to import data",
      source: self.class.name,
      provider_key: "powens",
      family: family,
      metadata: { powens_item_id: id, error_class: e.class.name, error_message: e.message }
    )
    raise
  end

  # Process each linked, visible Powens account, returning a per-account result array.
  def process_accounts
    return [] if powens_accounts.empty?

    powens_accounts.joins(:account).merge(Account.visible).map do |powens_account|
      result = PowensAccount::Processor.new(powens_account).process
      if result.is_a?(Hash) && result.with_indifferent_access[:success] == false
        { powens_account_id: powens_account.id, success: false, error: I18n.t("powens_item.errors.account_processing_failed") }
      else
        { powens_account_id: powens_account.id, success: true, result: result }
      end
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process account",
        source: self.class.name,
        provider_key: "powens",
        family: family,
        account_provider: powens_account.account_provider,
        metadata: { powens_item_id: id, powens_account_id: powens_account.id, error_class: e.class.name, error_message: e.message }
      )
      { powens_account_id: powens_account.id, success: false, error: I18n.t("powens_item.errors.account_processing_failed") }
    end
  end

  # Enqueue a balance sync for each visible linked account, returning per-account results.
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    accounts.visible.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to schedule sync for account",
        source: self.class.name,
        provider_key: "powens",
        family: family,
        account: account,
        metadata: { powens_item_id: id, account_id: account.id, error_class: e.class.name, error_message: e.message }
      )
      { account_id: account.id, success: false, error: I18n.t("powens_item.errors.account_sync_schedule_failed") }
    end
  end

  # Persist the latest raw accounts payload for this item.
  def upsert_powens_snapshot!(accounts_snapshot)
    assign_attributes(raw_payload: accounts_snapshot)
    save!
  end

  # True once at least one Powens account has been linked to a Sure account.
  def has_completed_initial_setup?
    accounts.any?
  end

  # Human-readable summary of linked vs. unlinked account counts.
  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts.zero?
      I18n.t("powens_item.sync_status.no_accounts")
    elsif unlinked_count.zero?
      I18n.t("powens_item.sync_status.all_synced", count: linked_count)
    else
      I18n.t("powens_item.sync_status.partial", linked: linked_count, unlinked: unlinked_count)
    end
  end

  # Number of Powens accounts linked to a Sure account.
  def linked_accounts_count
    account_counts[:linked]
  end

  # Number of unlinked Powens accounts still awaiting setup.
  def unlinked_accounts_count
    account_counts[:unlinked]
  end

  # Total number of Powens accounts under this item.
  def total_accounts_count
    account_counts[:total]
  end

  # Best available display name for the connected institution.
  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  # Distinct institution metadata across this item's accounts.
  def connected_institutions
    powens_accounts.includes(:account)
                   .where.not(institution_metadata: nil)
                   .map(&:institution_metadata)
                   .uniq { |inst| inst["name"] || inst["domain"] }
  end

  # Human-readable summary of connected institutions (none/one/count).
  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("powens_item.institution_summary.none")
    when 1
      institutions.first["name"].presence || I18n.t("powens_item.institution_summary.one")
    else
      I18n.t("powens_item.institution_summary.count", count: institutions.count)
    end
  end

  # True when a domain and access token are present and the item can call the Powens API.
  def credentials_configured?
    domain.present? && access_token.present?
  end

  # Accept both bare hosts ("my.biapi.pro") and full API URLs
  # ("https://my.biapi.pro/2.0/") as written in the Powens docs, then store
  # only the host. Keeps the domain field forgiving for manual entry.
  def self.normalize_domain(value)
    raw = value.to_s.strip
    return raw if raw.blank?

    if raw.start_with?("http://", "https://")
      uri = URI.parse(raw)
      return uri.host.to_s.strip if uri.host.present?
    end

    raw.split("/").first.to_s.strip
  rescue URI::InvalidURIError
    raw.split("/").first.to_s.strip
  end

  private

    def normalize_domain
      self.domain = self.class.normalize_domain(domain) if domain.present?
    end

    # Single query for all three account counts, reused across sync_status_summary
    # and the settings partial to avoid 3+ separate COUNT queries per rendered item.
    def account_counts
      @account_counts ||= begin
        rows = powens_accounts
                 .left_joins(:account_provider)
                 .pluck(Arel.sql("account_providers.id IS NOT NULL"), :ignored)

        linked = rows.count { |has_provider, _ignored| has_provider }
        unlinked = rows.count { |has_provider, ignored| !has_provider && !ignored }

        { linked: linked, unlinked: unlinked, total: rows.size }
      end
    end
end
