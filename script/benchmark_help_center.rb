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
  opts.banner = 'Usage: rails runner script/benchmark_help_center.rb -- --domains <comma-list> [--account-id <id>] [--curate]'
  opts.on('--domains DOMAINS', Array, 'Comma-separated list of domains') { |v| options[:domains] = v }
  opts.on('--account-id ID', Integer, 'Account to use for LLM context (defaults to first)') { |v| options[:account_id] = v }
  opts.on('--curate', 'Run only mapping + curation (skip scrape/rewrite; INDEX.md only)') { options[:curate_only] = true }
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

curate_index_md = lambda do |domain, plan, timings|
  buf = ["# Help center benchmark — #{domain} (curate only)", '',
         "Generated #{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S %Z')}", '',
         '## Pipeline timings',
         "- Map: #{timings[:map]}s",
         "- Curate: #{timings[:curate]}s",
         "- Total: #{timings[:total]}s",
         '', '## Articles by category', '']
  grouped = plan[:articles].group_by { |art| art[:category_name].to_s }
  plan[:categories].each do |cat|
    cat_articles = grouped[cat[:name].to_s] || []
    buf << "### #{cat[:name]} (#{cat_articles.size})"
    buf << cat[:description] if cat[:description].present?
    buf << ''
    cat_articles.each do |art|
      buf << "- #{art[:title]}"
      Array(art[:urls]).each { |u| buf << "    - source: #{u}" }
    end
    buf << ''
  end
  buf.join("\n")
end

elapsed = ->(t) { (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(1) }
run_id = Time.zone.now.strftime('%Y%m%d-%H%M%S')
original_account_name = account.name
overall_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
domain_stats = []

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
  stats = { domain: domain, picked: 0, generated: 0, url_counts: [], timings: timings }
  begin
    # Stage 1: Map
    print '  → Mapping… '
    $stdout.flush
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    map_response = Captain::Tools::FirecrawlService.new.map(domain, limit: 500, search: 'docs help support faq')
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
    stats[:picked] = plan[:articles].size
    stats[:url_counts] = plan[:articles].map { |a| Array(a[:urls]).size }
    puts "picked #{plan[:articles].size} articles across #{plan[:categories].size} categories in #{timings[:curate]}s"

    if plan[:articles].size < 3
      puts "  → Skipping completely (#{plan[:articles].size} articles < 3 threshold)"
      FileUtils.rmdir(out_dir) if Dir.empty?(out_dir)
      next
    end

    if options[:curate_only]
      timings[:total] = elapsed.call(total_started)
      out_dir.join('INDEX.md').write(curate_index_md.call(domain, plan, timings))
      puts "  → Wrote #{out_dir.relative_path_from(Rails.root)} (curate only, total #{timings[:total]}s)"
      next
    end

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
    stats[:generated] = succeeded
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
  ensure
    domain_stats << stats
  end
end

account.name = original_account_name

# ── Summary ───────────────────────────────────────────────────────
format_secs = lambda do |s|
  next '—' if s.nil?

  s.to_f >= 60 ? "#{(s.to_f / 60).to_i}m #{(s.to_f % 60).round}s" : "#{s.to_f.round(1)}s"
end

median = lambda do |arr|
  next 0 if arr.empty?

  sorted = arr.sort
  mid = sorted.size / 2
  sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

avg = ->(arr) { arr.empty? ? nil : arr.sum.to_f / arr.size }

total_picked    = domain_stats.sum { |d| d[:picked] }
total_generated = domain_stats.sum { |d| d[:generated] }
total_failed    = total_picked - total_generated
fail_pct        = total_picked.positive? ? (total_failed * 100.0 / total_picked).round : 0
gen_pct         = total_picked.positive? ? (total_generated * 100.0 / total_picked).round : 0
gen_counts      = domain_stats.map { |d| d[:generated] }
url_picks       = domain_stats.flat_map { |d| d[:url_counts] }
url_total       = url_picks.size
maps            = domain_stats.filter_map { |d| d[:timings][:map] }
curates         = domain_stats.filter_map { |d| d[:timings][:curate] }
rewrites        = domain_stats.filter_map { |d| d[:timings][:rewrite] }
totals          = domain_stats.filter_map { |d| d[:timings][:total] }
overall_total   = elapsed.call(overall_started)

pct = ->(part, whole) { whole.positive? ? format('%.1f', part * 100.0 / whole) : '0.0' }

puts ''
puts '═══ Summary ════════════════════════════════════════════════════════'
puts "Domains processed: #{domain_stats.size}"
puts ''
puts "Articles picked by curator: #{total_picked}"
unless options[:curate_only]
  puts "  Successfully generated:   #{total_generated} (#{gen_pct}%)"
  puts "  Failed to generate:       #{total_failed} (#{fail_pct}%)"
end
puts ''
if !options[:curate_only] && gen_counts.any?
  puts 'Per-domain article output'
  puts "  Min:    #{gen_counts.min}"
  puts "  Median: #{median.call(gen_counts)}"
  puts "  Mean:   #{format('%.1f', avg.call(gen_counts) || 0)}"
  puts "  Max:    #{gen_counts.max}"
  puts ''
  puts '  Distribution:'
  puts "    0 articles:       #{gen_counts.count(0)} domains   (full failure)"
  puts "    1 article:        #{gen_counts.count(1)} domains   (thin output)"
  puts "    2-5 articles:     #{gen_counts.count { |n| n.between?(2, 5) }} domains"
  puts "    6-10 articles:    #{gen_counts.count { |n| n.between?(6, 10) }} domains"
  puts "    11-12 articles:   #{gen_counts.count { |n| n.between?(11, 12) }} domains"
  puts ''
end
if url_total.positive?
  puts "Curator URL choices (across #{url_total} picks)"
  [1, 2, 3].each do |n|
    cnt = url_picks.count(n)
    label = n == 1 ? '1 URL:' : "#{n} URLs:"
    puts "  #{label.ljust(8)} #{cnt.to_s.rjust(3)} (#{pct.call(cnt, url_total)}%)"
  end
  puts ''
end
puts 'Timing aggregates'
puts "  Total wall time:    #{format_secs.call(overall_total)}"
puts '  Sum per stage:'
puts "    Map:              #{format_secs.call(maps.sum)}"
puts "    Curate:           #{format_secs.call(curates.sum)}"
puts "    Scrape + rewrite: #{format_secs.call(rewrites.sum)}" unless options[:curate_only]
puts '  Avg per domain:'
puts "    Map:              #{format_secs.call(avg.call(maps))}"
puts "    Curate:           #{format_secs.call(avg.call(curates))}"
puts "    Scrape + rewrite: #{format_secs.call(avg.call(rewrites))}" unless options[:curate_only]
puts "    Total:            #{format_secs.call(avg.call(totals))}"
puts ''
puts 'Done. Outputs in help_center_benchmarks/'

# rubocop:enable Metrics/BlockLength
