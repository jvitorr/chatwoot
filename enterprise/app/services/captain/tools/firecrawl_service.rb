class Captain::Tools::FirecrawlService
  BASE_URL = 'https://api.firecrawl.dev/v1'.freeze
  FIRECRAWL_EXCLUDE_TAGS = %w[iframe .sidebar .cookie-banner [role=navigation] [role=banner] [role=contentinfo]].freeze
  SCRAPE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

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

  def scrape(url, max_age: SCRAPE_MAX_AGE_MS)
    HTTParty.post(
      "#{BASE_URL}/scrape",
      body: scrape_payload(url, max_age: max_age),
      headers: headers
    )
  end

  def batch_scrape(urls, max_age: SCRAPE_MAX_AGE_MS, poll_interval: 2, timeout: 180)
    kickoff = HTTParty.post(
      "#{BASE_URL}/batch/scrape",
      body: batch_scrape_payload(urls, max_age: max_age),
      headers: headers
    )
    return kickoff unless kickoff.success?

    job_id = kickoff.parsed_response&.dig('id')
    return kickoff if job_id.blank?

    poll_batch(job_id, poll_interval: poll_interval, timeout: timeout)
  end

  def batch_status(job_id)
    HTTParty.get("#{BASE_URL}/batch/scrape/#{job_id}", headers: headers)
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

  def scrape_payload(url, max_age: SCRAPE_MAX_AGE_MS)
    { url: url }.merge(scrape_options(max_age: max_age)).to_json
  end

  def batch_scrape_payload(urls, max_age: SCRAPE_MAX_AGE_MS)
    { urls: Array(urls) }.merge(scrape_options(max_age: max_age)).to_json
  end

  def poll_batch(job_id, poll_interval:, timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      response = batch_status(job_id)
      return response unless response.success?

      status = response.parsed_response&.dig('status')
      return response if %w[completed failed cancelled].include?(status)
      return response if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep poll_interval
    end
  end

  def scrape_options(max_age: SCRAPE_MAX_AGE_MS)
    {
      onlyMainContent: true,
      formats: ['markdown'],
      excludeTags: FIRECRAWL_EXCLUDE_TAGS,
      maxAge: max_age
    }
  end

  def headers
    {
      'Authorization' => "Bearer #{@api_key}",
      'Content-Type' => 'application/json'
    }
  end
end
