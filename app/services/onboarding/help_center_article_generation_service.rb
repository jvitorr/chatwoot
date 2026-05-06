class Onboarding::HelpCenterArticleGenerationService
  MAP_LIMIT = 100
  SCRAPE_THREAD_POOL = 6

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

  def build_articles(planned)
    pool = [planned.size, SCRAPE_THREAD_POOL].min

    planned.each_slice(pool).flat_map do |batch|
      batch.map { |article| Thread.new { [article[:url].to_s, scrape_and_rewrite(article)] } }.map(&:value)
    end.to_h
  end

  def scrape_and_rewrite(article)
    raw = scrape_one(article[:url].to_s)
    return nil if raw.nil? || raw[:markdown].blank?

    rewrite(raw, article)
  rescue StandardError => e
    Rails.logger.warn "[HelpCenterArticleGeneration] build failed for #{article[:url]}: #{e.message}"
    nil
  end

  def scrape_one(url)
    response = Captain::Tools::FirecrawlService.new.scrape(url)
    return nil unless response.success?

    data = response.parsed_response&.dig('data')
    return nil if data.blank?

    {
      page_title: data.dig('metadata', 'title').to_s.strip,
      markdown: data['markdown'].to_s
    }
  end

  def rewrite(raw, article)
    response = Captain::Llm::ArticleWriterService.new(
      account: @account,
      source_markdown: raw[:markdown],
      source_url: article[:url].to_s,
      hint_title: article[:title].presence || raw[:page_title]
    ).perform
    return nil if response[:error]

    payload = response[:message] || {}
    return nil if payload[:content].blank? || payload[:title].blank?

    payload
  end

  def create_articles(planned, pages, categories_by_name)
    planned.filter_map do |article|
      page = pages[article[:url].to_s]
      next if page.nil? || page[:content].blank? || page[:title].blank?

      @portal.articles.create!(
        title: page[:title],
        description: page[:description].presence,
        content: page[:content],
        author_id: @user.id,
        category_id: categories_by_name[article[:category_name].to_s]&.id,
        status: :draft,
        meta: { source_url: article[:url] }
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
