require "test_helper"

class PowensAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @powens_item = PowensItem.create!(
      family: @family,
      name: "Test Powens",
      domain: "my.biapi.pro",
      access_token: "powens-access-token"
    )
  end

  test "maps Powens account types to Sure accountable types" do
    account = build_account(account_type: "checking")
    assert_equal "Depository", account.suggested_account_type
    assert_equal "checking", account.suggested_subtype

    account = build_account(account_type: "livret_a")
    assert_equal "Depository", account.suggested_account_type
    assert_equal "savings", account.suggested_subtype

    account = build_account(account_type: "pea")
    assert_equal "Investment", account.suggested_account_type
    assert_equal "brokerage", account.suggested_subtype

    account = build_account(account_type: "loan")
    assert_equal "Loan", account.suggested_account_type

    account = build_account(account_type: "unknown")
    assert_nil account.suggested_account_type
  end

  test "upserts a snapshot with balance, currency, disabled and type" do
    account = PowensAccount.create!(
      powens_item: @powens_item,
      name: "Initial",
      account_id: "456",
      currency: "EUR"
    )

    account.upsert_powens_snapshot!(
      id: 456,
      original_name: "LEP",
      balance: 150.25,
      currency: { iso_code: "EUR" },
      type: { name: "savings" },
      usage: "PRIV",
      disabled: "2026-08-01T00:00:00Z"
    )

    account.reload
    assert_equal "LEP", account.name
    assert_equal BigDecimal("150.25").to_s, account.current_balance.to_s
    assert_equal "EUR", account.currency
    assert_equal "savings", account.account_type
    assert_equal "PRIV", account.ownership_type
    assert_predicate account, :disabled?
    assert_predicate account, :needs_activation?
    assert_equal "my.biapi.pro", account.institution_metadata["domain"]
  end

  test "accepts the account type as a plain string (real API shape)" do
    account = PowensAccount.create!(
      powens_item: @powens_item,
      name: "Initial",
      account_id: "4",
      currency: "EUR"
    )

    account.upsert_powens_snapshot!(
      id: 4,
      original_name: "Compte Courant",
      balance: 4419.48,
      currency: { iso_code: "EUR" },
      type: "checking"
    )

    account.reload
    assert_equal "checking", account.account_type
    assert_equal "Depository", account.suggested_account_type
    assert_equal "checking", account.suggested_subtype
  end

  private

    def build_account(account_type:)
      PowensAccount.new(
        powens_item: @powens_item,
        name: "Account",
        account_id: "999",
        currency: "EUR",
        account_type: account_type
      )
    end
end
