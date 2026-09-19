require "test_helper"

class Provider::PowensTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :message, keyword_init: true)

  test "fetches accounts with the all flag and bearer auth" do
    requests = []

    Provider::Powens.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, headers: headers, query: query }
      FakeResponse.new(
        code: 200,
        message: "OK",
        body: {
          accounts: [
            { id: 123, name: "Compte courant", original_name: "Compte courant", balance: 1234.56, currency: { iso_code: "EUR" }, type: { name: "checking" } },
            { id: 456, name: "LEP", original_name: "LEP", balance: 50.0, currency: { iso_code: "EUR" }, type: { name: "savings" }, disabled: "2026-08-01T00:00:00Z" }
          ],
          balances: { "EUR" => 1284.56 },
          coming_balances: { "EUR" => 0 }
        }.to_json
      )
    }) do
      client = Provider::Powens.new(domain: "my.biapi.pro", access_token: "powens-token")
      accounts = client.get_accounts

      assert_equal [ 123, 456 ], accounts.map { |a| a[:id] }
      assert_equal "checking", accounts.first[:type][:name]
      assert_equal BigDecimal("1234.56").to_s, accounts.first[:balance].to_s
    end

    assert_equal 1, requests.size
    assert_match %r{/users/me/accounts}, requests.first[:url]
    assert_equal "all", requests.first[:query]
    assert_equal "Bearer powens-token", requests.first[:headers]["Authorization"]
  end

  test "fetches paginated transactions following _links.next.href" do
    next_url = "https://my.biapi.pro/2.0/users/me/accounts/123/transactions?limit=1000&cursor=abc"
    responses = [
      FakeResponse.new(
        code: 200,
        message: "OK",
        body: {
          transactions: [ { id: 1, id_account: 123, value: "-12.34", coming: false, date: "2026-01-19" } ],
          _links: { prev: nil, next: { href: next_url } }
        }.to_json
      ),
      FakeResponse.new(
        code: 200,
        message: "OK",
        body: {
          transactions: [ { id: 2, id_account: 123, value: "50.00", coming: true, date: "2026-01-20" } ],
          _links: { prev: nil, next: nil }
        }.to_json
      )
    ]
    requests = []

    Provider::Powens.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, headers: headers, query: query }
      responses.shift
    }) do
      client = Provider::Powens.new(domain: "my.biapi.pro", access_token: "powens-token")

      transactions = client.get_account_transactions(
        account_id: 123,
        since: Date.new(2026, 1, 1)
      )

      assert_equal [ 1, 2 ], transactions.map { |tx| tx[:id] }
    end

    assert_equal 2, requests.size
    assert_match %r{/users/me/accounts/123/transactions}, requests.first[:url]
    assert_equal "Bearer powens-token", requests.first[:headers]["Authorization"]
    assert_equal "2026-01-01", requests.first[:query][:min_date]
    assert_equal 1000, requests.first[:query][:limit]
    # Pagination follows the opaque next URL as-is.
    assert_equal next_url, requests.second[:url]
  end

  test "refuses non-biapi.pro domains to protect the token" do
    error = assert_raises(Provider::Powens::PowensError) do
      Provider::Powens.new(domain: "evil.example.com", access_token: "token")
    end
    assert_equal :configuration_error, error.error_type
  end

  test "maps 401 to unauthorized and 409 conflicts to conflict with the API code" do
    client = Provider::Powens.new(domain: "my.biapi.pro", access_token: "powens-token")

    Provider::Powens.stub(:get, ->(url, headers:, query: nil) {
      FakeResponse.new(code: 401, message: "Unauthorized", body: { code: "badCredentials" }.to_json)
    }) do
      error = assert_raises(Provider::Powens::PowensError) { client.get_accounts }
      assert_equal :unauthorized, error.error_type
    end

    Provider::Powens.stub(:get, ->(url, headers:, query: nil) {
      FakeResponse.new(code: 409, message: "Conflict", body: { code: "noAccount" }.to_json)
    }) do
      error = assert_raises(Provider::Powens::PowensError) { client.get_accounts }
      assert_equal :conflict, error.error_type
      assert_match(/noAccount/, error.message)
    end
  end

  test "generates a temporary code for the connect webview" do
    requests = []

    Provider::Powens.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, headers: headers, query: query }
      FakeResponse.new(
        code: 200,
        message: "OK",
        body: { code: "temp-code-123", type: "temporary", access: "single", expires_in: 1800 }.to_json
      )
    }) do
      client = Provider::Powens.new(domain: "my.biapi.pro", access_token: "powens-token")

      assert_equal "temp-code-123", client.get_temporary_code
    end

    assert_equal 1, requests.size
    assert_match %r{/auth/token/code}, requests.first[:url]
    assert_equal "singleAccess", requests.first[:query][:type]
    assert_equal "Bearer powens-token", requests.first[:headers]["Authorization"]
  end

  test "returns nil when the temporary code payload is empty" do
    Provider::Powens.stub(:get, ->(url, headers:, query: nil) {
      FakeResponse.new(code: 200, message: "OK", body: {}.to_json)
    }) do
      client = Provider::Powens.new(domain: "my.biapi.pro", access_token: "powens-token")

      assert_nil client.get_temporary_code
    end
  end

  test "lists connections with their sync states" do
    requests = []

    Provider::Powens.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, query: query }
      FakeResponse.new(
        code: 200,
        message: "OK",
        body: {
          connections: [
            { id: 3, id_connector: 1, state: "SCARequired", active: true },
            { id: 7, id_connector: 4, state: nil, active: true }
          ]
        }.to_json
      )
    }) do
      client = Provider::Powens.new(domain: "my.biapi.pro", access_token: "powens-token")
      connections = client.get_connections

      assert_equal [ 3, 7 ], connections.map { |connection| connection[:id] }
      assert_equal "SCARequired", connections.first[:state]
      assert_nil connections.second[:state]
    end

    assert_match %r{/users/me/connections}, requests.first[:url]
  end

  test "requests a bank refresh for a connection with a PUT" do
    requests = []

    Provider::Powens.stub(:put, ->(url, headers:, query: nil, body: nil) {
      requests << { url: url, headers: headers, query: query }
      FakeResponse.new(code: 200, message: "OK", body: { id: 3, state: nil }.to_json)
    }) do
      client = Provider::Powens.new(domain: "my.biapi.pro", access_token: "powens-token")
      client.sync_connection(3)
    end

    assert_equal 1, requests.size
    assert_match %r{/users/me/connections/3}, requests.first[:url]
    assert_equal true, requests.first[:query][:psu_requested]
    assert_equal "Bearer powens-token", requests.first[:headers]["Authorization"]
  end

  test "builds a webauth url to resume a connection" do
    requests = []

    Provider::Powens.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, query: query }
      FakeResponse.new(code: 200, message: "OK", body: { url: "https://webauth.powens.com/x" }.to_json)
    }) do
      client = Provider::Powens.new(domain: "my.biapi.pro", access_token: "powens-token")
      url = client.webauth_url(
        connection_id: 3,
        client_id: "client-1",
        redirect_uri: "http://localhost:3000/powens_items/callback",
        state: "item-id"
      )

      assert_equal "https://webauth.powens.com/x", url
    end

    assert_match %r{/webauth-url}, requests.first[:url]
    assert_equal 3, requests.first[:query][:id_connection]
    assert_equal "client-1", requests.first[:query][:client_id]
    assert_equal "item-id", requests.first[:query][:state]
  end
end
