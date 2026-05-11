class Captain::Tools::FirecrawlService
  BASE_URL = 'https://api.firecrawl.dev/v1'.freeze
  FIRECRAWL_EXCLUDE_TAGS = %w[iframe .sidebar .cookie-banner [role=navigation] [role=banner] [role=contentinfo]].freeze

  def self.configured?
    InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY')&.value
                      .present?
  end

  def initialize
    @api_key = InstallationConfig.find_by!(name: 'CAPTAIN_FIRECRAWL_API_KEY').value
    raise 'Missing API key' if @api_key.blank?
  end

  def perform(url, webhook_url, crawl_limit = 10)
    HTTParty.post(
      "#{BASE_URL}/crawl",
      body: crawl_payload(url, webhook_url, crawl_limit),
      headers: headers
    )
  rescue StandardError => e
    raise "Failed to crawl URL: #{e.message}"
  end

  def scrape(url)
    HTTParty.post(
      "#{BASE_URL}/scrape",
      body: scrape_payload(url),
      headers: headers
    )
  end

  # v2/map returns links as objects with url, title, and description (v1 returns
  # bare URL strings), giving the curator real signal to filter on. Other
  # endpoints stay on v1 — their request payloads aren't v2-compatible.
  def map(url, limit: 100, include_subdomains: false, search: nil)
    body = { url: url, limit: limit, includeSubdomains: include_subdomains, search: search }.compact
    HTTParty.post(
      'https://api.firecrawl.dev/v2/map',
      body: body.to_json,
      headers: headers
    )
  end

  private

  def crawl_payload(url, webhook_url, crawl_limit)
    {
      url: url,
      maxDepth: 50,
      ignoreSitemap: false,
      limit: crawl_limit,
      webhook: webhook_url,
      scrapeOptions: scrape_options
    }.to_json
  end

  def scrape_payload(url)
    { url: url }.merge(scrape_options).to_json
  end

  def scrape_options
    {
      onlyMainContent: true,
      formats: ['markdown'],
      excludeTags: FIRECRAWL_EXCLUDE_TAGS
    }
  end

  def headers
    {
      'Authorization' => "Bearer #{@api_key}",
      'Content-Type' => 'application/json'
    }
  end
end
