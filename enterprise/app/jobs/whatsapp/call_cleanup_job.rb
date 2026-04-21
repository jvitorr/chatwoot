class Whatsapp::CallCleanupJob < ApplicationJob
  queue_as :low

  def perform
    expire_stale_ringing_calls
    expire_stale_in_progress_calls
  end

  private

  def expire_stale_ringing_calls
    Call.whatsapp.ringing.where('created_at < ?', 2.minutes.ago).find_each do |call|
      call.update!(status: 'no_answer', end_reason: 'timeout')
      Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'no_answer')
    end
  end

  def expire_stale_in_progress_calls
    Call.whatsapp.where(status: 'in_progress').where('started_at < ?', 3.hours.ago).find_each do |call|
      terminate_media_session(call)
      call.update!(status: 'failed', end_reason: 'timeout')
      Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'failed')
    end
  end

  def terminate_media_session(call)
    return unless call.media_session_id.present?

    Whatsapp::MediaServerClient.new.terminate_session(call.media_session_id)
  rescue Whatsapp::MediaServerClient::ConnectionError, Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.error "[WHATSAPP CALL CLEANUP] Failed to terminate media session #{call.media_session_id}: #{e.message}"
  end
end
