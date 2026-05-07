class Captain::Documents::ScheduleSyncsJob < ApplicationJob
  queue_as :scheduled_jobs

  PER_ACCOUNT_HOURLY_CAP = 50
  GLOBAL_HOURLY_CAP = 1000
  SYNC_STALE_TIMEOUT = Captain::Document::SYNC_STALE_TIMEOUT
  DAILY_SYNC_JITTER = 4.hours
  WEEKLY_SYNC_JITTER = 1.day
  MONTHLY_SYNC_JITTER = 4.days

  def perform
    @remaining_global_capacity = GLOBAL_HOURLY_CAP
    sync_intervals = Enterprise::Account.captain_document_sync_intervals
    stats = { accounts_scanned: 0, accounts_enabled: 0, accounts_scheduled: 0, documents_enqueued: 0 }

    Account.joins(:captain_documents).distinct.find_each(batch_size: 100) do |account|
      break if @remaining_global_capacity <= 0

      stats[:accounts_scanned] += 1
      next unless account.feature_enabled?('captain_document_auto_sync')

      stats[:accounts_enabled] += 1
      interval = account.captain_document_sync_interval(sync_intervals)
      next unless interval

      stats[:accounts_scheduled] += 1
      stats[:documents_enqueued] += enqueue_due_documents(account, interval)
    end

    log_scheduler_summary(stats)
  end

  private

  def enqueue_due_documents(account, interval)
    syncing = Captain::Document.sync_statuses[:syncing]
    synced = Captain::Document.sync_statuses[:synced]
    failed = Captain::Document.sync_statuses[:failed]
    stale_cutoff = SYNC_STALE_TIMEOUT.ago
    due_cutoff = (interval + sync_jitter(account, interval)).ago
    per_account_limit = [PER_ACCOUNT_HOURLY_CAP, @remaining_global_capacity].min
    enqueued_count = 0

    account.captain_documents.syncable.where(status: :available).where(
      '(sync_status = ? AND last_synced_at < ?) OR (sync_status = ? AND last_sync_attempted_at < ?) OR ' \
      '(sync_status = ? AND last_sync_attempted_at < ?)',
      synced, due_cutoff, failed, due_cutoff, syncing, stale_cutoff
    ).order(Arel.sql('last_sync_attempted_at ASC NULLS FIRST'), :id).limit(per_account_limit).each do |document|
      next unless document.syncable?

      # Reserve the sync slot before enqueueing so later scheduler runs skip this document while the job is queued.
      mark_sync_started(document)
      Captain::Documents::PerformSyncJob.set(queue: :purgable).perform_later(document)
      @remaining_global_capacity -= 1
      enqueued_count += 1
    end

    enqueued_count
  end

  def sync_jitter(account, interval)
    # Spread recurring refreshes by account so longer cadences do not all become due in the same scheduler run.
    jitter_window = if interval <= 1.day
                      DAILY_SYNC_JITTER
                    elsif interval <= 1.week
                      WEEKLY_SYNC_JITTER
                    else
                      MONTHLY_SYNC_JITTER
                    end
    jitter_bucket_count = (jitter_window / 1.hour).to_i + 1

    (account.id % jitter_bucket_count).hours
  end

  def log_scheduler_summary(stats)
    payload = {
      event: 'completed',
      global_cap_hit: @remaining_global_capacity <= 0,
      remaining_global_capacity: @remaining_global_capacity
    }.merge(stats)

    Rails.logger.info("[Captain::Documents::ScheduleSyncsJob] #{payload.to_json}")
  end

  def mark_sync_started(document)
    document.update!(
      sync_status: :syncing,
      sync_step: nil,
      last_sync_error_code: nil,
      last_sync_attempted_at: Time.current
    )
  end
end
