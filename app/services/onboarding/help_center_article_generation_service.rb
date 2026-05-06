class Onboarding::HelpCenterArticleGenerationService
  MAP_LIMIT = 200
  SCRAPE_THREAD_POOL = 3

  def initialize(account, user, portal)
    @account = account
    @user = user
    @portal = portal
  end

  def perform
    skip_reason = preflight_skip_reason
    return log_skip(skip_reason) if skip_reason

    links = discover_links
    return log_skip('map returned no links') if links.empty?

    plan = curate(links)
    return log_skip('curation returned no articles') if plan[:articles].blank?

    generate(plan)
  rescue StandardError => e
    Rails.logger.error "[HelpCenterArticleGeneration] #{e.class}: #{e.message}"
    nil
  end

  private

  def preflight_skip_reason
    return 'portal already has articles' if @portal.articles.exists?
    return 'Firecrawl not configured' unless Captain::Tools::FirecrawlService.configured?
    return 'no website url' if website_url.blank?
  end

  def generate(plan)
    categories_by_name = create_categories(plan[:categories])
    pages = build_articles(plan[:articles])
    create_articles(plan[:articles], pages, categories_by_name)
  end

  def discover_links
    response = Captain::Tools::FirecrawlService.new.map(website_url, limit: MAP_LIMIT)
    return [] unless response.success?

    Array(response.parsed_response&.dig('links')).map do |link|
      link.is_a?(Hash) ? link : { 'url' => link.to_s }
    end
  end

  def curate(links)
    response = Captain::Llm::HelpCenterCurationService.new(account: @account, links: links).perform
    return { categories: [], articles: [] } if response[:error]

    response[:message] || { categories: [], articles: [] }
  end

  def create_categories(categories)
    locale = @portal.default_locale
    categories.each_with_index.with_object({}) do |(cat, idx), acc|
      name = cat[:name].to_s.strip
      next if name.blank?

      slug = "#{name.parameterize}-#{SecureRandom.hex(3)}"
      record = @portal.categories.create!(
        name: name,
        description: cat[:description].to_s.strip.presence,
        slug: slug,
        locale: locale,
        position: (idx + 1) * 10
      )
      acc[name] = record
    end
  end

  # TODO: replace this in-process Thread.new fan-out with per-article Sidekiq jobs
  # before wiring this service into the onboarding flow. Threads inside a single
  # Rails request/job each check out their own AR connection and exhaust the
  # pool quickly; Sidekiq workers run isolated and scale independently.
  def build_articles(planned)
    pool = [planned.size, SCRAPE_THREAD_POOL].min

    planned.each_with_index.each_slice(pool).flat_map do |batch|
      batch.map { |article, idx| Thread.new { [idx, scrape_and_rewrite(article)] } }.map(&:value)
    end.to_h
  end

  def scrape_and_rewrite(article)
    source_pages = collect_source_pages(article)
    return nil if source_pages.empty?

    rewrite(source_pages, article)
  rescue StandardError => e
    Rails.logger.warn "[HelpCenterArticleGeneration] build failed for #{Array(article[:urls]).join(', ')}: #{e.message}"
    nil
  end

  def collect_source_pages(article)
    Array(article[:urls]).map(&:to_s).reject(&:blank?).filter_map do |url|
      raw = scrape_one(url)
      next if raw.nil? || raw[:markdown].blank?

      { url: url, markdown: raw[:markdown], page_title: raw[:page_title] }
    end
  end

  def scrape_one(url)
    response = Captain::Tools::FirecrawlService.new.scrape(url)
    return nil unless response.success?

    data = response.parsed_response&.dig('data')
    return nil if data.blank?

    # Firecrawl returns API 200 even when the scraped page itself failed —
    # the target page's real status lives in data.metadata.statusCode.
    target_status = data.dig('metadata', 'statusCode')
    return nil if target_status.present? && !(200..299).cover?(target_status)

    {
      page_title: data.dig('metadata', 'title').to_s.strip,
      markdown: data['markdown'].to_s
    }
  end

  def rewrite(source_pages, article)
    response = Captain::Llm::ArticleWriterService.new(
      account: @account,
      source_pages: source_pages,
      hint_title: article[:title].presence || source_pages.first[:page_title]
    ).perform
    return nil if response[:error]

    payload = response[:message] || {}
    return nil if payload[:content].blank? || payload[:title].blank?

    payload.merge(source_urls: source_pages.pluck(:url))
  end

  def create_articles(planned, pages, categories_by_name)
    planned.each_with_index.filter_map do |article, idx|
      page = pages[idx]
      next if page.nil? || page[:content].blank? || page[:title].blank?

      @portal.articles.create!(
        title: page[:title],
        description: page[:description].presence,
        content: page[:content],
        author_id: @user.id,
        category_id: categories_by_name[article[:category_name].to_s]&.id,
        status: :draft,
        meta: { source_urls: page[:source_urls] }
      )
    end
  end

  def website_url
    @website_url ||= @account.domain.presence || brand_info[:domain].presence
  end

  def brand_info
    @brand_info ||= (@account.custom_attributes['brand_info'] || {}).deep_symbolize_keys
  end

  def log_skip(reason)
    Rails.logger.info "[HelpCenterArticleGeneration] Skipping for account #{@account.id}: #{reason}"
    nil
  end
end
