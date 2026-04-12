class Whatsapp::CallTranscriptionJob < ApplicationJob
  queue_as :low

  retry_on ActiveStorage::FileNotFoundError, wait: 2.seconds, attempts: 3
  discard_on Faraday::BadRequestError do |job, error|
    Rails.logger.warn("[WHATSAPP CALL] Discarding transcription job: call_id=#{job.arguments.first}, status=#{error.response&.dig(:status)}")
  end

  def perform(call_id)
    call = Call.whatsapp.find_by(id: call_id)
    return if call.blank? || !call.recording.attached?

    Whatsapp::CallTranscriptionService.new(call).perform
  end
end
