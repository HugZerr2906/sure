class Provider::PowensAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("PowensAccount", self)

  # Sure accountable types that can be created from Powens accounts.
  def self.supported_account_types
    %w[Depository Loan Investment]
  end

  # Connection config hashes for each of the family's configured Powens items.
  def self.connection_configs(family:)
    return [] unless family.can_connect_powens?

    family.powens_items.active.ordered.select(&:credentials_configured?).map do |powens_item|
      connection_config_for(powens_item)
    end
  end

  # Build a Powens API client for the resolved item, or nil if none is usable.
  def self.build_provider(family: nil, powens_item_id: nil)
    return nil unless family.present?

    powens_item = resolve_powens_item(family, powens_item_id)
    return nil unless powens_item&.credentials_configured?

    Provider::Powens.new(domain: powens_item.domain, access_token: powens_item.access_token)
  end

  # Build the settings connection-config hash for a single Powens item.
  def self.connection_config_for(powens_item)
    path_params = ->(extra = {}) { extra.merge(powens_item_id: powens_item.id) }

    {
      key: "powens_#{powens_item.id}",
      name: powens_item.name.presence || I18n.t("providers.powens.name"),
      description: I18n.t("providers.powens.description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_powens_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_powens_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  # Provider key used across the sync/account-provider machinery.
  def provider_name
    "powens"
  end

  # Route to trigger a manual sync for this provider account's item.
  def sync_path
    Rails.application.routes.url_helpers.sync_powens_item_path(item)
  end

  # The PowensItem backing this provider account.
  def item
    provider_account.powens_item
  end

  # Powens holdings are never deletable by the sync machinery (V0 has no holdings).
  def can_delete_holdings?
    false
  end

  # Institution domain from account metadata, or nil.
  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["domain"]
  end

  # Institution name from account metadata, falling back to the item's.
  def institution_name
    metadata = provider_account.institution_metadata
    metadata&.dig("name").presence || item&.institution_name
  end

  # Institution URL from account metadata, falling back to the item's.
  def institution_url
    metadata = provider_account.institution_metadata
    metadata&.dig("url").presence || item&.institution_url
  end

  # Brand color for the institution, from the item.
  def institution_color
    item&.institution_color
  end

  # Resolve the target Powens item: the requested one, else the first configured.
  def self.resolve_powens_item(family, powens_item_id)
    if powens_item_id.present?
      item = family.powens_items.active.find_by(id: powens_item_id)
      return item if item&.credentials_configured?

      return nil
    end

    family.powens_items.active.ordered.find(&:credentials_configured?)
  end
  private_class_method :resolve_powens_item
end
