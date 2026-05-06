# TODO: delete this entire file before merging — it's a throwaway benchmark
# harness that duplicates the production pipeline so generated articles can be
# reviewed as .md files instead of DB rows. Not for shipping.
#
# Ad-hoc benchmark for the help-center generation pipeline.
# Will be deleted once benchmarks are reviewed.
#
# Usage:
#   bundle exec rails runner script/benchmark_help_center.rb -- --domains acme.com,intercom.com
#   bundle exec rails runner script/benchmark_help_center.rb -- --domains acme.com --account-id 1
#
# Output: help_center_benchmarks/<timestamp>-<domain>/INDEX.md + per-article .md files

require 'optparse'
require 'fileutils'

# rubocop:disable Metrics/BlockLength

options = {}
OptionParser.new do |opts|
  opts.banner = 'Usage: rails runner script/benchmark_help_center.rb -- --domains <comma-list> [--account-id <id>]'
  opts.on('--domains DOMAINS', Array, 'Comma-separated list of domains') { |v| options[:domains] = v }
  opts.on('--account-id ID', Integer, 'Account to use for LLM context (defaults to first)') { |v| options[:account_id] = v }
end.parse!(ARGV)

abort 'Error: --domains is required.' if options[:domains].blank?

account = options[:account_id] ? Account.find(options[:account_id]) : Account.first
abort 'Error: No account available; pass --account-id <id>.' unless account
abort 'Error: Firecrawl is not configured (CAPTAIN_FIRECRAWL_API_KEY missing).' unless Captain::Tools::FirecrawlService.configured?

out_root = Rails.root.join('help_center_benchmarks')
FileUtils.mkdir_p(out_root)

sanitize = lambda do |name|
  cleaned = name.to_s.strip.gsub(%r{[/\\:*?"<>|]}, '_').gsub(/\s+/, ' ').slice(0, 120)
  cleaned.presence || 'untitled'
end

article_md = lambda do |page, art|
  source_lines = Array(page[:source_urls]).map { |u| "  - #{u}" }.join("\n")
  <<~MD
    ---
    title: #{page[:title]}
    description: #{page[:description].to_s.tr("\n", ' ')}
    category: #{art[:category_name]}
    source_urls:
    #{source_lines}
    ---

    #{page[:content]}
  MD
end

index_md = lambda do |domain, plan, pages, timings|
  buf = ["# Help center benchmark — #{domain}", '',
         "Generated #{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S %Z')}", '',
         '## Pipeline timings',
         "- Map: #{timings[:map]}s",
         "- Curate: #{timings[:curate]}s",
         "- Scrape + rewrite: #{timings[:rewrite]}s",
         "- Total: #{timings[:total]}s",
         '', '## Articles by category', '']
  indexed = plan[:articles].each_with_index.to_a
  grouped = indexed.group_by { |art, _| art[:category_name].to_s }
  plan[:categories].each do |cat|
    cat_articles = grouped[cat[:name].to_s] || []
    buf << "### #{cat[:name]} (#{cat_articles.size})"
    buf << cat[:description] if cat[:description].present?
    buf << ''
    cat_articles.each do |art, idx|
      page = pages[idx]
      ok = page && page[:content].present?
      label = page ? page[:title] : art[:title]
      file_path = "#{sanitize.call(cat[:name])}/#{sanitize.call(label)}.md"
      buf << (ok ? "- ✓ [#{label}](#{file_path})" : "- ✗ #{label} (failed)")
      Array(art[:urls]).each { |u| buf << "    - source: #{u}" }
    end
    buf << ''
  end
  buf.join("\n")
end

elapsed = ->(t) { (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(1) }
run_id = Time.zone.now.strftime('%Y%m%d-%H%M%S')
original_account_name = account.name

options[:domains].each do |raw|
  domain = raw.to_s.strip
  next if domain.blank?

  account.name = domain # transient — never saved
  out_dir = out_root.join("#{run_id}-#{sanitize.call(domain)}")
  FileUtils.mkdir_p(out_dir)

  puts ''
  puts "═══ #{domain} ═══════════════════════════════════════════════"
  total_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  timings = {}

  # Stage 1: Map
  print '  → Mapping… '
  $stdout.flush
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  map_response = Captain::Tools::FirecrawlService.new.map(domain, limit: 200)
  unless map_response.success?
    puts "FAILED (HTTP #{map_response.code})"
    next
  end
  links = Array(map_response.parsed_response&.dig('links')).map { |l| l.is_a?(Hash) ? l : { 'url' => l.to_s } }
  if links.empty?
    puts 'no links returned, skipping'
    next
  end
  timings[:map] = elapsed.call(t0)
  puts "found #{links.size} links in #{timings[:map]}s"

  # Stage 2: Curate
  print '  → Curating… '
  $stdout.flush
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  curation = Captain::Llm::HelpCenterCurationService.new(account: account, links: links).perform
  if curation[:error]
    puts "FAILED (#{curation[:error]})"
    next
  end
  plan = curation[:message] || { categories: [], articles: [] }
  if plan[:articles].blank?
    puts 'no articles picked, skipping'
    next
  end
  timings[:curate] = elapsed.call(t0)
  puts "picked #{plan[:articles].size} articles across #{plan[:categories].size} categories in #{timings[:curate]}s"

  # Stage 3: Scrape + rewrite (parallel, 3 threads)
  print '  → Scraping & rewriting… '
  $stdout.flush
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  results = plan[:articles].each_with_index.each_slice(3).flat_map do |batch|
    batch.map do |art, idx|
      Thread.new do
        urls = Array(art[:urls]).map(&:to_s).reject(&:blank?)
        source_pages = []
        per_url_errors = []
        urls.each do |u|
          scrape = Captain::Tools::FirecrawlService.new.scrape(u)
          unless scrape.success?
            per_url_errors << "#{u}: scrape http #{scrape.code}"
            next
          end
          data = scrape.parsed_response&.dig('data')
          if data.blank? || data['markdown'].to_s.blank?
            per_url_errors << "#{u}: blank scrape"
            next
          end
          target_status = data.dig('metadata', 'statusCode')
          if target_status.present? && !(200..299).cover?(target_status)
            per_url_errors << "#{u}: target page status #{target_status}"
            next
          end
          source_pages << { url: u, markdown: data['markdown'].to_s, page_title: data.dig('metadata', 'title').to_s }
        end
        next [idx, { _error: "all urls failed (#{per_url_errors.join('; ')})", urls: urls }] if source_pages.empty?

        writer = Captain::Llm::ArticleWriterService.new(
          account: account,
          source_pages: source_pages,
          hint_title: art[:title].presence || source_pages.first[:page_title]
        ).perform
        next [idx, { _error: "writer error: #{writer[:error]}", urls: urls }] if writer[:error]

        payload = writer[:message] || {}
        next [idx, { _error: 'writer returned blank content', urls: urls }] if payload[:content].blank?
        next [idx, { _error: 'writer returned blank title', urls: urls }] if payload[:title].blank?

        [idx, payload.merge(source_urls: source_pages.pluck(:url))]
      rescue StandardError => e
        [idx, { _error: "exception #{e.class}: #{e.message}", urls: Array(art[:urls]) }]
      end
    end.map(&:value)
  end.to_h
  pages = results.transform_values { |v| v[:_error] ? nil : v }
  failures = results.select { |_, v| v.is_a?(Hash) && v[:_error] }
  succeeded = pages.values.count { |p| p && p[:content].present? }
  timings[:rewrite] = elapsed.call(t0)
  puts "succeeded #{succeeded}/#{plan[:articles].size} in #{timings[:rewrite]}s"
  failures.each { |idx, info| puts "      ✗ article ##{idx} (#{Array(info[:urls]).join(', ')}) — #{info[:_error]}" }

  # Persist .md files
  plan[:articles].each_with_index do |art, idx|
    page = pages[idx]
    next if page.nil? || page[:content].blank? || page[:title].blank?

    cat_dir = out_dir.join(sanitize.call(art[:category_name].to_s.presence || 'Uncategorized'))
    FileUtils.mkdir_p(cat_dir)
    cat_dir.join("#{sanitize.call(page[:title])}.md").write(article_md.call(page, art))
  end

  timings[:total] = elapsed.call(total_started)
  out_dir.join('INDEX.md').write(index_md.call(domain, plan, pages, timings))

  puts "  → Wrote #{out_dir.relative_path_from(Rails.root)} (total #{timings[:total]}s)"
end

account.name = original_account_name
puts ''
puts 'Done. Outputs in help_center_benchmarks/'

# rubocop:enable Metrics/BlockLength
