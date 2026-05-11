class Onboarding::HelpCenterArticleGenerationService
  MAP_LIMIT = 500
  MIN_ARTICLES = 3
  SCRAPE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

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
    return log_skip("only #{plan[:articles].size} articles curated (< #{MIN_ARTICLES} threshold)") if plan[:articles].size < MIN_ARTICLES

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
    response = Captain::Tools::FirecrawlService.new.map(website_url, limit: MAP_LIMIT, search: 'docs help support faq')
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

  def build_articles(planned)
    scrapes = batch_scrape_urls(planned.flat_map { |a| Array(a[:urls]).map(&:to_s) }.reject(&:blank?).uniq)

    planned.each_with_index.with_object({}) do |(article, idx), acc|
      result = build_article(article, scrapes)
      acc[idx] = result if result
    end
  end

  def build_article(article, scrapes)
    source_pages = collect_source_pages(article, scrapes)
    return nil if source_pages.empty?

    rewrite(source_pages, article)
  rescue StandardError => e
    Rails.logger.warn "[HelpCenterArticleGeneration] build failed for #{Array(article[:urls]).join(', ')}: #{e.message}"
    nil
  end

  def batch_scrape_urls(urls)
    return {} if urls.empty?

    response = Captain::Tools::FirecrawlService.new.batch_scrape(urls, max_age: SCRAPE_MAX_AGE_MS)
    return {} unless response.success?

    Array(response.parsed_response&.dig('data')).each_with_object({}) do |data, acc|
      page = normalize_scrape(data)
      next if page.nil?

      acc[page[:url]] = page
    end
  end

  def normalize_scrape(data)
    return nil if data.blank?

    target_status = data.dig('metadata', 'statusCode')
    return nil if target_status.present? && !(200..299).cover?(target_status)
    return nil if data['markdown'].to_s.blank?

    {
      url: data.dig('metadata', 'sourceURL') || data.dig('metadata', 'url'),
      page_title: data.dig('metadata', 'title').to_s.strip,
      markdown: data['markdown'].to_s
    }
  end

  def collect_source_pages(article, scrapes)
    Array(article[:urls]).map(&:to_s).reject(&:blank?).filter_map do |url|
      page = scrapes[url]
      next if page.nil?

      { url: url, markdown: page[:markdown], page_title: page[:page_title] }
    end
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
