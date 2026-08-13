class PowensAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # Maps Powens AccountTypeName values to Sure accountable types/subtypes.
  # Powens' official AccountTypeName list has no "lep" entry, so a LEP typically
  # arrives as "savings", "csl" or "unknown" — confirm with real data before
  # relying on a specific mapping.
  POWENS_ACCOUNT_TYPE_MAP = {
    "checking" => { accountable_type: "Depository", subtype: "checking" },
    "savings" => { accountable_type: "Depository", subtype: "savings" },
    "livret_a" => { accountable_type: "Depository", subtype: "savings" },
    "livret_b" => { accountable_type: "Depository", subtype: "savings" },
    "ldds" => { accountable_type: "Depository", subtype: "savings" },
    "pel" => { accountable_type: "Depository", subtype: "savings" },
    "cel" => { accountable_type: "Depository", subtype: "savings" },
    "csl" => { accountable_type: "Depository", subtype: "savings" },
    "cat" => { accountable_type: "Depository", subtype: "savings" },
    "deposit" => { accountable_type: "Depository", subtype: "savings" },
    "loan" => { accountable_type: "Loan" },
    "market" => { accountable_type: "Investment", subtype: "brokerage" },
    "pea" => { accountable_type: "Investment", subtype: "brokerage" },
    "lifeinsurance" => { accountable_type: "Investment" },
    "capitalisation" => { accountable_type: "Investment" },
    "article83" => { accountable_type: "Investment" },
    "per" => { accountable_type: "Investment" },
    "perco" => { accountable_type: "Investment" },
    "perp" => { accountable_type: "Investment" },
    "madelin" => { accountable_type: "Investment" },
    "pee" => { accountable_type: "Investment" },
    "rsp" => { accountable_type: "Investment" },
    "crowdlending" => { accountable_type: "Investment" }
  }.freeze

  INSTITUTION_NAME = "Powens".freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :powens_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, presence: true
  validates :account_id, uniqueness: { scope: :powens_item_id, allow_nil: true }

  # Powens accounts with no linked Sure account.
  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  # Unlinked accounts that still need a setup decision (i.e. not explicitly skipped).
  scope :needs_setup, -> { unlinked.where(ignored: false) }

  # The linked Sure account, if any.
  def current_account
    account
  end

  # Suggested Sure accountable type derived from Powens' account type, or nil.
  def suggested_account_type
    POWENS_ACCOUNT_TYPE_MAP[account_type.to_s]&.fetch(:accountable_type)
  end

  # Suggested Sure subtype (e.g. checking/savings/brokerage) for this Powens account, or nil.
  def suggested_subtype
    POWENS_ACCOUNT_TYPE_MAP[account_type.to_s]&.[](:subtype)
  end

  # Powens accounts are disabled by default for legal compliance; linking an
  # account in Sure acts as the PSU consent and enables it on Powens' side.
  def needs_activation?
    disabled?
  end

  # Persist the latest Powens account snapshot, normalizing balance/currency/metadata.
  def upsert_powens_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access
    currency = snapshot[:currency].is_a?(Hash) ? snapshot[:currency].with_indifferent_access : {}

    assign_attributes(
      current_balance: parse_balance(snapshot[:balance]),
      currency: parse_currency(currency[:iso_code] || currency[:code]) || "EUR",
      name: snapshot[:original_name].presence || snapshot[:name].presence || I18n.t("powens_account.fallback"),
      account_id: snapshot[:id].to_s,
      account_status: snapshot[:disabled].present? ? "disabled" : "active",
      account_type: extract_account_type(snapshot),
      ownership_type: snapshot[:usage],
      provider: "powens",
      disabled: snapshot[:disabled].present?,
      institution_metadata: {
        name: INSTITUTION_NAME,
        domain: powens_item.domain
      }.compact,
      raw_payload: account_snapshot
    )

    save!
  end

  # Persist the latest raw transactions payload for this account.
  def upsert_powens_transactions_snapshot!(transactions_snapshot)
    assign_attributes(raw_transactions_payload: transactions_snapshot)
    save!
  end

  private

    # Powens returns the account type as a plain string in practice
    # ("checking", "savings", ...), while the docs describe an AccountType
    # object ({ id:, name: }). Accept both forms.
    def extract_account_type(snapshot)
      value = snapshot[:type]
      return value.to_s.presence unless value.is_a?(Hash)

      value.with_indifferent_access[:name].to_s.presence
    end

    # Parse a Powens decimal balance into a BigDecimal, defaulting to 0 on bad input.
    def parse_balance(value)
      return 0 if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      0
    end

    # CurrencyNormalizable hook: warn when a Powens currency code is unrecognized.
    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Powens account #{id}, defaulting to EUR")
    end
end
