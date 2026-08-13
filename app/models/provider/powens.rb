# Powens (Biapi) API client for the Sure Finance personal fork.
#
# Talks to the Powens aggregation API (https://{domain}.biapi.pro/2.0) with a
# user access token supplied by the account holder. Covers the bank account and
# transaction endpoints only; Wealth & Loans / investments are a later step.
class Provider::Powens
  include HTTParty
  extend SslConfigurable

  API_VERSION = "2.0".freeze
  DEFAULT_PAGE_SIZE = 1000 # Powens caps list pages at 1000.

  # Only biapi.pro hosts are accepted so the bearer token is never sent to an
  # arbitrary domain (the domain is user-provided in settings).
  DOMAIN_PATTERN = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.biapi\.pro\z/

  headers "User-Agent" => "Sure Finance Powens Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :domain, :access_token

  # Build a client with the family's Powens domain and user access token.
  # Raises on a blank token or a domain outside biapi.pro.
  def initialize(domain:, access_token:)
    @domain = domain.to_s.strip
    @access_token = access_token.to_s.strip

    validate_domain!
    raise PowensError.new("Powens access token is required", :configuration_error) if @access_token.blank?
  end

  # GET /users/me/accounts?all — all accounts (including disabled ones; Powens
  # disables newly-discovered accounts by default for legal compliance).
  def get_accounts
    payload = get("users/me/accounts", query: "all")
    Array(payload[:accounts])
  end

  # GET /users/me/accounts/{accountId}/transactions — all transactions for an
  # account, following relational pagination (_links.next.href) until exhausted.
  def get_account_transactions(account_id:, since: nil)
    query = { limit: DEFAULT_PAGE_SIZE }
    query[:min_date] = format_date(since) if since.present?

    path = "users/me/accounts/#{ERB::Util.url_encode(account_id.to_s)}/transactions"
    fetch_all_pages(path, query: query)
  end

  # POST /users/me/accounts/{accountId}?all { "disabled": false }
  # Enabling an account represents the PSU's consent on Powens' side.
  def enable_account(account_id)
    path = "users/me/accounts/#{ERB::Util.url_encode(account_id.to_s)}"
    post(path, query: "all", body: { disabled: false }.to_json)
  end

  private

    RETRYABLE_ERRORS = [
      SocketError,
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::ETIMEDOUT,
      EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2

    # Follow Powens' relational pagination: each page carries opaque
    # _links.next.href links (absolute URLs) that encapsulate the original
    # filtering; loop until there is no next page.
    def fetch_all_pages(path, query: {})
      results = []
      payload = get(path, query: query.presence)

      loop do
        results.concat(Array(payload[:transactions]))
        next_href = payload.dig(:_links, :next, :href)
        break if next_href.blank?

        payload = get(next_href)
      end

      results
    end

    # Issues a GET request. `path_or_url` may be a relative path (prefixed with
    # the base URL) or an absolute URL (used when following pagination links).
    def get(path_or_url, query: nil)
      with_retries("GET #{path_or_url}") do
        url = resolve_url(path_or_url)
        response = self.class.get(url, headers: auth_headers, query: query)
        handle_response(response)
      end
    end

    # Issues a POST request to a relative path.
    def post(path, query: nil, body: nil)
      with_retries("POST #{path}") do
        url = resolve_url(path)
        response = self.class.post(
          url,
          headers: auth_headers.merge("Content-Type" => "application/json"),
          query: query,
          body: body
        )
        handle_response(response)
      end
    end

    # Resolves a relative path against the base URL, or validates an absolute
    # URL so the bearer token is only ever sent to the configured biapi.pro host.
    def resolve_url(path_or_url)
      value = path_or_url.to_s
      return "#{base_url}/#{value}" unless value.start_with?("http")

      uri = URI.parse(value)
      unless uri.scheme == "https" && uri.host == base_host
        raise PowensError.new("Refusing to send credentials to untrusted host: #{uri.host.inspect}", :invalid_url)
      end

      value
    rescue URI::InvalidURIError
      raise PowensError.new("Invalid Powens API URL", :invalid_url)
    end

    def base_url
      "https://#{domain}/#{API_VERSION}"
    end

    def base_host
      @base_host ||= URI.parse(base_url).host
    end

    def validate_domain!
      unless domain.match?(DOMAIN_PATTERN)
        raise PowensError.new("Invalid Powens domain: #{domain.inspect}", :configuration_error)
      end
    end

    # Bearer-auth headers sent with every request.
    def auth_headers
      {
        "Authorization" => "Bearer #{access_token}",
        "Accept" => "application/json"
      }
    end

    # Run the block, retrying transient network errors with exponential backoff.
    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1
        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "Powens API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        end

        Rails.logger.error("Powens API: #{operation_name} failed after #{max_retries} retries: #{e.class}: #{e.message}")
        raise PowensError.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
      end
    end

    # Exponential backoff delay (with jitter), capped at 30 seconds.
    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    # Map an HTTP response to parsed data or a typed PowensError by status code.
    def handle_response(response)
      case response.code
      when 200, 201
        parse_response_body(response)
      when 204
        {}
      when 400
        raise PowensError.new("Bad request to Powens API (status=#{response.code})", :bad_request)
      when 401
        raise PowensError.new("Invalid Powens access token", :unauthorized)
      when 403
        raise PowensError.new("Powens access forbidden - check token permissions", :access_forbidden)
      when 404
        raise PowensError.new("Powens resource not found", :not_found)
      when 409
        raise PowensError.new("Powens conflict: #{extract_error_code(response)}", :conflict)
      when 429
        raise PowensError.new("Powens rate limit exceeded", :rate_limited)
      else
        raise PowensError.new("Powens API error (status=#{response.code})", :server_error)
      end
    end

    def parse_response_body(response)
      body = response.body.to_s
      return {} if body.blank?

      JSON.parse(body).with_indifferent_access
    rescue JSON::ParserError => e
      Rails.logger.error "Powens API: failed to parse response body: #{e.class}"
      raise PowensError.new("Failed to parse Powens API response", :parse_error)
    end

    def extract_error_code(response)
      parsed = JSON.parse(response.body.to_s)
      parsed.is_a?(Hash) ? parsed["code"].presence || parsed["error"].presence : nil
    rescue JSON::ParserError
      nil
    end

    def format_date(value)
      value.is_a?(Date) ? value.iso8601 : value.to_s
    end

  public

    # Typed error raised by the client; carries an error_type symbol used by
    # callers to decide recovery (e.g. mark the item as requires_update).
    class PowensError < StandardError
      attr_reader :error_type

      def initialize(message, error_type = nil)
        super(message)
        @error_type = error_type
      end
    end
end
