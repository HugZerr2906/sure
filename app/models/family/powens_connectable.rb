module Family::PowensConnectable
  extend ActiveSupport::Concern

  included do
    has_many :powens_items, dependent: :destroy
  end

  # Whether this family may connect Powens accounts (always true).
  def can_connect_powens?
    true
  end

  # Create a Powens item with the given domain/token and trigger an initial sync.
  def create_powens_item!(domain:, access_token:, item_name: nil)
    powens_item = powens_items.create!(
      name: item_name || I18n.t("family.powens.create_powens_item.default_name"),
      domain: domain,
      access_token: access_token
    )

    powens_item.sync_later
    powens_item
  end

  # True when any active Powens item has usable credentials.
  def has_powens_credentials?
    powens_items.active.any?(&:credentials_configured?)
  end
end
