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
  <<~MD
    ---
    title: #{page[:title]}
    description: #{page[:description].to_s.tr("\n", ' ')}
    category: #{art[:category_name]}
    source_url: #{art[:url]}
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
  grouped = plan[:articles].group_by { |a| a[:category_name].to_s }
  plan[:categories].each do |cat|
    cat_articles = grouped[cat[:name].to_s] || []
    buf << "### #{cat[:name]} (#{cat_articles.size})"
    buf << cat[:description] if cat[:description].present?
    buf << ''
    cat_articles.each do |art|
      page = pages[art[:url].to_s]
      ok = page && page[:content].present?
      label = page ? page[:title] : art[:title]
      file_path = "#{sanitize.call(cat[:name])}/#{sanitize.call(label)}.md"
      buf << (ok ? "- ✓ [#{label}](#{file_path})" : "- ✗ #{label} (failed)")
      buf << "    - source: #{art[:url]}"
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
  unique_articles = plan[:articles].uniq { |a| a[:url].to_s }
  results = unique_articles.each_slice(3).flat_map do |batch|
    batch.map do |art|
      Thread.new do
        url = art[:url].to_s
        scrape = Captain::Tools::FirecrawlService.new.scrape(url)
        next [url, { _error: "scrape http #{scrape.code}" }] unless scrape.success?

        data = scrape.parsed_response&.dig('data')
        next [url, { _error: 'scrape returned no data' }] if data.blank?
        next [url, { _error: 'scrape returned blank markdown' }] if data['markdown'].to_s.blank?

        target_status = data.dig('metadata', 'statusCode')
        next [url, { _error: "target page status #{target_status}" }] if target_status.present? && !(200..299).cover?(target_status)

        writer = Captain::Llm::ArticleWriterService.new(
          account: account,
          source_markdown: data['markdown'].to_s,
          source_url: url,
          hint_title: art[:title].presence || data.dig('metadata', 'title').to_s
        ).perform
        next [url, { _error: "writer error: #{writer[:error]}" }] if writer[:error]

        payload = writer[:message] || {}
        next [url, { _error: 'writer returned blank content' }] if payload[:content].blank?
        next [url, { _error: 'writer returned blank title' }] if payload[:title].blank?

        [url, payload]
      rescue StandardError => e
        [url, { _error: "exception #{e.class}: #{e.message}" }]
      end
    end.map(&:value)
  end.to_h
  pages = results.transform_values { |v| v[:_error] ? nil : v }
  failures = results.select { |_, v| v.is_a?(Hash) && v[:_error] }
  succeeded = pages.values.count { |p| p && p[:content].present? }
  timings[:rewrite] = elapsed.call(t0)
  puts "succeeded #{succeeded}/#{unique_articles.size} in #{timings[:rewrite]}s"
  failures.each { |url, info| puts "      ✗ #{url} — #{info[:_error]}" }

  # Persist .md files
  plan[:articles].each do |art|
    page = pages[art[:url].to_s]
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
