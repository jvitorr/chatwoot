class Whatsapp::CallRecordingFetchJob < ApplicationJob
  queue_as :default

  retry_on Whatsapp::MediaServerClient::ConnectionError, wait: 5.seconds, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def perform(call_id)
    call = Call.find(call_id)
    return unless call.media_session_id.present?

    client = Whatsapp::MediaServerClient.new
    recording_data = client.download_recording(call.media_session_id)
    return if recording_data.blank?

    call.recording.attach(
      io: StringIO.new(recording_data.force_encoding('BINARY')),
      filename: "call_#{call.id}_#{call.provider_call_id}.ogg",
      content_type: 'audio/ogg'
    )

    Whatsapp::CallMessageBuilder.update_recording_url!(call: call)
    Whatsapp::CallTranscriptionJob.perform_later(call.id) if call.recording.attached?
  rescue Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.warn "[WHATSAPP CALL] Recording not available for session #{call.media_session_id}: #{e.message}"
  end
end
