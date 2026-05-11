class Onboarding::HelpCenterArticleWriterJob < ApplicationJob
  queue_as :low

  retry_on Firecrawl::FirecrawlError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.send(:on_writer_failure, error)
  end

  discard_on CustomExceptions::HelpCenter::ArticleBuildFailed do |job, error|
    job.send(:on_writer_failure, error)
  end

  def perform(generation, article_index)
    spec = generation.plan['articles'][article_index].with_indifferent_access

    Onboarding::HelpCenterArticleBuilder.new(
      account: generation.account,
      portal: generation.portal,
      user: generation.account.administrators.first,
      article: spec
    ).perform

    finalize(generation)
  end

  private

  def on_writer_failure(error)
    generation = arguments.first
    Rails.logger.warn "[HelpCenterWriterJob] gen=#{generation.id} failed: #{error.class} #{error.message}"
    finalize(generation)
  end

  def finalize(generation)
    HelpCenterGeneration.update_counters(generation.id, articles_finished: 1) # rubocop:disable Rails/SkipsModelValidations
    generation.reload
    return unless generation.all_finished? && !generation.terminal?

    generation.update!(status: :completed, finished_at: Time.current)
  end
end
