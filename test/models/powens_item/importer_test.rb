require "test_helper"

class PowensItem::ImporterTest < ActiveSupport::TestCase
  class FakePowensProvider
    attr_reader :transaction_calls

    def initialize(accounts: nil, transactions: nil)
      @transaction_calls = []
      @accounts = accounts
      @transactions = transactions
    end

    def get_accounts
      @accounts || [
        {
          id: 123,
          name: "Compte courant",
          original_name: "Compte courant",
          balance: 1234.56,
          currency: { iso_code: "EUR" },
          type: { name: "checking" }
        },
        {
          id: 456,
          name: "LEP",
          original_name: "LEP",
          balance: 50.0,
          currency: { iso_code: "EUR" },
          type: { name: "savings" }
        }
      ]
    end

    def get_account_transactions(account_id:, since: nil)
      @transaction_calls << { account_id: account_id, since: since }
      @transactions || [ posted_transaction ]
    end

    private

      def posted_transaction
        {
          id: 9001,
          id_account: 123,
          date: "2026-01-19",
          value: "-20.00",
          original_wording: "Carrefour",
          wording: "Carrefour",
          coming: false,
          type: "card"
        }
      end
  end

  setup do
    @family = families(:empty)
    @powens_item = PowensItem.create!(
      family: @family,
      name: "Test Powens",
      domain: "my.biapi.pro",
      access_token: "powens-access-token"
    )
    @powens_account = PowensAccount.create!(
      powens_item: @powens_item,
      name: "Old name",
      account_id: "123",
      currency: "EUR"
    )
    @account = Account.create!(
      family: @family,
      name: "Compte courant",
      accountable: Depository.new(subtype: "checking"),
      balance: 0,
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @powens_account)
  end

  test "imports account snapshots and stores transactions" do
    provider = FakePowensProvider.new

    result = PowensItem::Importer.new(@powens_item, powens_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]
    assert_equal 1, result[:accounts_created] # the unlinked LEP account
    assert_equal 1, result[:transactions_imported]

    @powens_account.reload
    assert_equal "Compte courant", @powens_account.name
    assert_equal BigDecimal("1234.56").to_s, @powens_account.current_balance.to_s
    assert_equal "checking", @powens_account.account_type
    assert_equal "123", provider.transaction_calls.first[:account_id]

    assert_equal [ 9001 ], @powens_account.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "skips deleted accounts and keeps disabled accounts discoverable" do
    provider = FakePowensProvider.new(
      accounts: [
        { id: 111, name: "Deleted account", original_name: "Deleted account", balance: 0, deleted: "2026-07-01T00:00:00Z", type: { name: "checking" } },
        { id: 222, name: "Disabled LEP", original_name: "Disabled LEP", balance: 100, disabled: "2026-08-01T00:00:00Z", type: { name: "savings" } }
      ]
    )

    result = PowensItem::Importer.new(@powens_item, powens_provider: provider).import

    assert result[:success]
    created = @powens_item.powens_accounts.reload.where.not(id: @powens_account.id)
    assert_equal [ "222" ], created.map(&:account_id)
    assert created.first.disabled?
  end

  test "returns a failed result when accounts cannot be fetched" do
    provider = Class.new do
      def get_accounts
        raise Provider::Powens::PowensError.new("Invalid Powens access token", :unauthorized)
      end
    end.new

    result = PowensItem::Importer.new(@powens_item, powens_provider: provider).import

    refute result[:success]
    assert result[:error].present?
    assert_equal 0, result[:accounts_created]
    assert_equal 0, result[:transactions_imported]
    @powens_item.reload
    assert_predicate @powens_item, :requires_update?
  end

  test "merges transactions by id so a coming keeps its latest version" do
    import_with(transactions: [ coming_transaction(id: 7000) ])
    import_with(transactions: [ posted(id: 7000, wording: "Carrefour") ])

    @powens_account.reload
    assert_equal [ 7000 ], @powens_account.raw_transactions_payload.map { |tx| tx["id"] }
    assert_equal false, @powens_account.raw_transactions_payload.first["coming"]
  end

  private

    def import_with(transactions:)
      provider = FakePowensProvider.new(transactions: transactions)
      PowensItem::Importer.new(@powens_item, powens_provider: provider).import
    end

    def coming_transaction(id:)
      {
        id: id,
        id_account: 123,
        date: "2026-01-15",
        value: "-8.00",
        original_wording: "Carte en cours",
        coming: true,
        type: "card"
      }
    end

    def posted(id:, wording:)
      {
        id: id,
        id_account: 123,
        date: "2026-01-16",
        value: "-8.00",
        original_wording: wording,
        wording: wording,
        coming: false,
        type: "card"
      }
    end
end
