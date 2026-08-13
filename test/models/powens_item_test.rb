require "test_helper"

class PowensItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "normalizes a full API URL into its bare host" do
    item = PowensItem.new(
      family: @family,
      name: "Test",
      domain: "https://persohugo-sandbox.biapi.pro/2.0/",
      access_token: "token"
    )

    assert item.valid?, item.errors.full_messages.join(", ")
    assert_equal "persohugo-sandbox.biapi.pro", item.domain
  end

  test "normalizes a bare host with a trailing path" do
    item = PowensItem.new(
      family: @family,
      name: "Test",
      domain: "my.biapi.pro/2.0",
      access_token: "token"
    )

    assert item.valid?, item.errors.full_messages.join(", ")
    assert_equal "my.biapi.pro", item.domain
  end

  test "rejects non-biapi.pro domains with a clear error" do
    item = PowensItem.new(
      family: @family,
      name: "Test",
      domain: "https://evil.example.com/2.0/",
      access_token: "token"
    )

    refute item.valid?
    assert item.errors[:domain].any?
  end
end
