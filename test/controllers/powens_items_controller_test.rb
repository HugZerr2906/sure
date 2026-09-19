require "test_helper"

class PowensItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  fixtures :users, :families

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @powens_item = PowensItem.create!(
      family: @family,
      name: "Test Powens",
      domain: "my.biapi.pro",
      access_token: "powens-access-token",
      client_id: "client-123"
    )
  end

  test "connect_bank redirects to the Powens webview with a temporary code" do
    Provider::Powens.any_instance.expects(:get_temporary_code).returns("temp-code-123")

    post connect_bank_powens_item_url(@powens_item)

    assert_response :see_other
    location = @response.location
    assert_match "webview.powens.com/connect", location
    assert_match "domain=my.biapi.pro", location
    assert_match "client_id=client-123", location
    assert_match "code=temp-code-123", location
    assert_match "state=#{@powens_item.id}", location
    assert_match CGI.escape("http://www.example.com/powens_items/callback"), location
  end

  test "connect_bank requires a client id" do
    @powens_item.update_column(:client_id, nil)

    post connect_bank_powens_item_url(@powens_item)

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("powens_items.connect_bank.no_client_id"), flash[:alert]
  end

  test "connect_bank reports provider errors without redirecting to Powens" do
    Provider::Powens.any_instance.expects(:get_temporary_code)
      .raises(Provider::Powens::PowensError.new("Invalid Powens access token", :unauthorized))

    post connect_bank_powens_item_url(@powens_item)

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("powens_items.connect_bank.api_error"), flash[:alert]
  end

  test "callback renders the landing page and syncs the item from the state param" do
    assert_enqueued_with(job: SyncJob) do
      get powens_items_callback_url(connection_id: "42", state: @powens_item.id)
    end

    assert_response :success
    assert_match "42", @response.body
  end

  test "callback renders the error without syncing" do
    get powens_items_callback_url(error: "access_denied", error_description: "cancelled")

    assert_response :success
    assert_match "access_denied", @response.body
  end

  test "refresh asks Powens to sync the connections and queues a Sure sync" do
    Provider::Powens.any_instance
      .expects(:get_connections)
      .returns([ ActiveSupport::HashWithIndifferentAccess.new(id: 3, state: "SCARequired") ])
    Provider::Powens.any_instance.expects(:sync_connection).with(3)

    assert_enqueued_with(job: SyncJob) do
      post refresh_powens_item_url(@powens_item)
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("powens_items.refresh.success"), flash[:notice]
  end

  test "reauthorize opens the Powens webview scoped to the connector" do
    Provider::Powens.any_instance
      .expects(:get_connections)
      .returns([ ActiveSupport::HashWithIndifferentAccess.new(id: 3, state: "SCARequired", id_connector: 1) ])
    Provider::Powens.any_instance.expects(:get_temporary_code).returns("temp-code-123")

    post reauthorize_powens_item_url(@powens_item)

    assert_response :see_other
    location = @response.location
    assert_match "webview.powens.com/connect", location
    assert_match "connector_ids=1", location
    assert_match "code=temp-code-123", location
    assert_match "state=#{@powens_item.id}", location
  end

  test "reauthorize reports when the item has no connection" do
    Provider::Powens.any_instance.expects(:get_connections).returns([])

    post reauthorize_powens_item_url(@powens_item)

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("powens_items.reauthorize.nothing_to_resume"), flash[:alert]
  end

  test "resume signals Powens and queues a Sure sync" do
    Provider::Powens.any_instance
      .expects(:get_connections)
      .returns([ ActiveSupport::HashWithIndifferentAccess.new(id: 3, state: "decoupled") ])
    Provider::Powens.any_instance.expects(:resume_connection).with(3)

    assert_enqueued_with(job: SyncJob) do
      post resume_powens_item_url(@powens_item)
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("powens_items.resume.success"), flash[:notice]
  end

  test "resume reports when no connection needs a resume signal" do
    Provider::Powens.any_instance
      .expects(:get_connections)
      .returns([ ActiveSupport::HashWithIndifferentAccess.new(id: 3, state: nil) ])

    post resume_powens_item_url(@powens_item)

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("powens_items.resume.nothing_to_resume"), flash[:alert]
  end
end
