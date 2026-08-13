module PowensItem::Provided
  extend ActiveSupport::Concern

  # Build a Powens API client from this item's domain and token, or nil if unconfigured.
  def powens_provider
    return nil unless credentials_configured?

    Provider::Powens.new(domain: domain, access_token: access_token)
  end

  # The syncer responsible for importing and processing this item's data.
  def syncer
    PowensItem::Syncer.new(self)
  end
end
