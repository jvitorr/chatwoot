# rubocop:disable Metrics/BlockLength
namespace :onboarding do
  desc 'Reset onboarding for an account (triggers the onboarding flow again). Usage: rake onboarding:reset[account_id]'
  task :reset, [:account_id] => :environment do |_task, args|
    abort 'Error: Please provide an account ID' if args[:account_id].blank?

    account = Account.find_by(id: args[:account_id])
    abort "Error: Account with ID '#{args[:account_id]}' not found" unless account

    account.custom_attributes['onboarding_step'] = 'account_details'
    account.save!

    puts "Onboarding has been reset for account '#{account.name}' (ID: #{account.id})"
  end

  # TODO: delete this `generate_help_center` task before merging — it duplicates
  # the production pipeline (Onboarding::HelpCenterArticleGenerationService) and
  # is only here as an interactive dev aid for testing.
  desc 'Interactively (re)create a help center for an account. Usage: rake onboarding:generate_help_center'
  task generate_help_center: :environment do
    print 'Account ID: '
    account_id = $stdin.gets&.strip
    abort 'Error: Account ID required' if account_id.blank?

    account = Account.find_by(id: account_id)
    abort "Error: Account '#{account_id}' not found" unless account

    user = account.administrators.first || account.users.first
    abort "Error: Account '#{account_id}' has no users to author articles" unless user

    abort 'Error: Firecrawl is not configured (CAPTAIN_FIRECRAWL_API_KEY missing).' unless Captain::Tools::FirecrawlService.configured?

    brand_info     = (account.custom_attributes['brand_info'] || {}).deep_symbolize_keys
    default_domain = account.domain.presence || brand_info[:domain].presence
    print(default_domain.present? ? "Domain [#{default_domain}]: " : 'Domain: ')
    domain_input = $stdin.gets&.strip
    website_url  = domain_input.presence || default_domain
    abort 'Error: Domain required.' if website_url.blank?

    existing = account.portals
    if existing.exists?
      cat_count     = Category.where(portal_id: existing.ids).count
      article_count = Article.where(portal_id: existing.ids).count
      print "Found existing help center with #{cat_count} #{'category'.pluralize(cat_count)} " \
            "and #{article_count} #{'article'.pluralize(article_count)}, type Y/y to delete: "
      answer = $stdin.gets&.strip
      abort 'Aborted.' unless %w[Y y].include?(answer)

      existing.find_each do |portal|
        portal.articles.destroy_all
        portal.categories.destroy_all
        portal.destroy
      end
      puts 'Deleted existing help center.'
    end

    portal = Onboarding::HelpCenterCreationService.new(account, user).perform
    abort 'Error: Portal creation failed' unless portal

    puts ''
    puts "Created portal '#{portal.name}' (slug: #{portal.slug}) in locale '#{portal.default_locale}'."

    total_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = ->(t) { (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(1) }

    # ── Stage 1: Map ──────────────────────────────────────────────────────
    puts ''
    print "→ [1/4] Mapping website (#{website_url})… "
    $stdout.flush
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    map_response = Captain::Tools::FirecrawlService.new.map(website_url, limit: 200)
    abort "Error: Firecrawl /map returned HTTP #{map_response.code}" unless map_response.success?
    links = Array(map_response.parsed_response&.dig('links')).map { |l| l.is_a?(Hash) ? l : { 'url' => l.to_s } }
    abort 'Error: /map returned no links.' if links.empty?
    puts "found #{links.size} #{'link'.pluralize(links.size)} in #{elapsed.call(t0)}s"

    # ── Stage 2: Curate ───────────────────────────────────────────────────
    puts ''
    print '→ [2/4] Curating with LLM… '
    $stdout.flush
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    curation = Captain::Llm::HelpCenterCurationService.new(account: account, links: links).perform
    abort "Error: Curation failed: #{curation[:error]}" if curation[:error]
    plan = curation[:message] || { categories: [], articles: [] }
    abort 'Error: Curation returned no articles.' if plan[:articles].blank?

    grouped = plan[:articles].group_by { |a| a[:category_name].to_s }
    puts "picked #{plan[:articles].size} articles across #{plan[:categories].size} categories in #{elapsed.call(t0)}s"
    puts ''
    plan[:categories].each do |cat|
      cat_articles = grouped[cat[:name].to_s] || []
      puts "   #{cat[:name]} (#{cat_articles.size} #{'article'.pluralize(cat_articles.size)})"
      puts "     #{cat[:description]}" if cat[:description].present?
      cat_articles.each do |art|
        puts "     • #{art[:title]}"
        puts "         #{art[:url]}"
      end
      puts ''
    end

    print 'Proceed with article generation? [Y/n]: '
    $stdout.flush
    confirm = $stdin.gets&.strip
    abort 'Aborted.' unless confirm.blank? || %w[Y y].include?(confirm)

    # ── Stage 3: Scrape + LLM rewrite (parallel) ──────────────────────────
    puts ''
    planned_articles = plan[:articles].uniq { |a| a[:url].to_s }
    print "→ [3/4] Scraping & rewriting #{planned_articles.size} pages in parallel (3 threads)… "
    $stdout.flush
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pages = planned_articles.each_slice(3).flat_map do |batch|
      batch.map do |art|
        Thread.new do
          url = art[:url].to_s
          scrape_response = Captain::Tools::FirecrawlService.new.scrape(url)
          next [url, nil] unless scrape_response.success?

          data = scrape_response.parsed_response&.dig('data')
          next [url, nil] if data.blank? || data['markdown'].to_s.blank?

          target_status = data.dig('metadata', 'statusCode')
          next [url, nil] if target_status.present? && !(200..299).cover?(target_status)

          writer = Captain::Llm::ArticleWriterService.new(
            account: account,
            source_markdown: data['markdown'].to_s,
            source_url: url,
            hint_title: art[:title].presence || data.dig('metadata', 'title').to_s
          ).perform
          next [url, nil] if writer[:error]

          payload = writer[:message] || {}
          next [url, nil] if payload[:content].blank? || payload[:title].blank?

          [url, payload]
        rescue StandardError
          [url, nil]
        end
      end.map(&:value)
    end.to_h
    succeeded = pages.values.count { |p| p && p[:content].present? }
    puts "succeeded #{succeeded}/#{planned_articles.size} in #{elapsed.call(t0)}s"
    abort 'Error: All scrape+rewrite calls failed; nothing to persist.' if succeeded.zero?

    # ── Stage 4: Persist ──────────────────────────────────────────────────
    puts ''
    print '→ [4/4] Persisting categories + draft articles… '
    $stdout.flush
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    locale = portal.default_locale
    categories_by_name = plan[:categories].each_with_index.with_object({}) do |(cat, idx), acc|
      name = cat[:name].to_s.strip
      next if name.blank?

      acc[name] = portal.categories.create!(
        name: name,
        description: cat[:description].to_s.strip.presence,
        slug: "#{name.parameterize}-#{SecureRandom.hex(3)}",
        locale: locale,
        position: (idx + 1) * 10
      )
    end

    written = plan[:articles].filter_map do |article|
      page = pages[article[:url].to_s]
      next if page.nil? || page[:content].blank? || page[:title].blank?

      portal.articles.create!(
        title: page[:title],
        description: page[:description].presence,
        content: page[:content],
        author_id: user.id,
        category_id: categories_by_name[article[:category_name].to_s]&.id,
        status: :draft,
        meta: { source_url: article[:url] }
      )
    end
    puts "wrote #{categories_by_name.size} categories, #{written.size} articles in #{elapsed.call(t0)}s"

    puts ''
    puts "✓ Help center ready in #{elapsed.call(total_started)}s. Portal ##{portal.id} (#{portal.slug})"
  end
end
# rubocop:enable Metrics/BlockLength
