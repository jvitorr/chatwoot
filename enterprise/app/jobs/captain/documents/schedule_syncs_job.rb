class Captain::Documents::ScheduleSyncsJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Account.joins(:captain_documents).distinct.find_each do |account|
      interval = account.captain_document_sync_interval
      next unless interval && account.captain_document_auto_sync_enabled?

      enqueue_due_documents(account, interval)
    end
  end

  private

  def enqueue_due_documents(account, interval)
    syncing = Captain::Document.sync_statuses[:syncing]
    stale_cutoff = Captain::Documents::PerformSyncJob::LOCK_TIMEOUT.ago

    account.captain_documents.where(status: :available).where(
      'last_sync_attempted_at IS NULL OR last_sync_attempted_at < ? OR (sync_status = ? AND last_sync_attempted_at < ?)',
      interval.ago, syncing, stale_cutoff
    ).find_each do |document|
      next if document.pdf_document?

      Captain::Documents::PerformSyncJob.perform_later(document)
    end
  end
end
