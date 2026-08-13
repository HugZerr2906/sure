require "test_helper"

class PowensEntry::ProcessorTest < ActiveSupport::TestCase
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
      name: "Compte courant",
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

  test "flips the sign: Powens negative (money out) becomes a positive Sure expense" do
    entry = process_transaction(
      id: 1,
      value: "-20.00",
      original_wording: "Carrefour",
      date: "2026-01-19",
      coming: false
    )

    assert_equal "powens_1", entry.external_id
    assert_equal BigDecimal("20.00").to_s, entry.amount.to_s
    assert_equal Date.new(2026, 1, 19), entry.date
    assert_equal "Carrefour", entry.name
    assert_equal "powens", entry.source
    refute entry.entryable.pending?
  end

  test "keeps income negative in Sure convention" do
    entry = process_transaction(
      id: 2,
      value: "1500.00",
      original_wording: "Salaire",
      date: "2026-01-31",
      coming: false
    )

    assert_equal BigDecimal("-1500.00").to_s, entry.amount.to_s
  end

  test "marks coming transactions as pending" do
    entry = process_transaction(
      id: 3,
      value: "-8.00",
      original_wording: "Carte en cours",
      date: "2026-01-15",
      coming: true
    )

    assert_predicate entry.entryable, :pending?
    assert_equal true, entry.entryable.extra.dig("powens", "pending")
  end

  test "falls back to editable wording when original_wording is missing" do
    entry = process_transaction(
      id: 4,
      value: "-5.00",
      wording: "Lidl",
      date: "2026-02-01",
      coming: false
    )

    assert_equal "Lidl", entry.name
  end

  private

    def process_transaction(attributes)
      transaction = {
        id_account: 123,
        value: "-1.00",
        coming: false,
        date: "2026-01-01"
      }.merge(attributes)

      PowensEntry::Processor.new(transaction, powens_account: @powens_account).process
    end
end
