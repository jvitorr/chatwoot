module Enterprise::Concerns::Attachment
  extend ActiveSupport::Concern

  included do
    after_create_commit :enqueue_audio_transcription
    # Broadcast the message update so the FE bubble picks up the new audio
    # attachment immediately. Without this, the FE has to wait until Whisper
    # finishes (or fall back to a page refresh) — and if Whisper returns blank,
    # the bubble never gets the audio at all.
    after_create_commit :broadcast_message_update_for_audio
  end

  private

  def enqueue_audio_transcription
    return unless file_type.to_sym == :audio

    Messages::AudioTranscriptionJob.perform_later(id)
  end

  def broadcast_message_update_for_audio
    return unless file_type.to_sym == :audio
    return unless message

    message.reload.send_update_event
  end
end
