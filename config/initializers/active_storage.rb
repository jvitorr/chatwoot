# Allow audio attachments (call recordings, voice notes) to serve inline so the
# in-app <audio> player can stream them. Without this, ActiveStorage's blob model
# forces Content-Disposition: attachment for any MIME outside the default allowlist
# (images + PDF), which makes the browser download instead of play.
Rails.application.config.active_storage.content_types_allowed_inline += %w[
  audio/webm
  audio/ogg
  audio/mpeg
  audio/mp4
  audio/x-m4a
  audio/wav
  audio/x-wav
]

module ActiveStorageDirectUploadMetadataFilter
  INTERNAL_METADATA_KEYS = %w[identified analyzed composed].freeze

  private

  def blob_args
    super.tap do |args|
      args[:metadata]&.except!(*INTERNAL_METADATA_KEYS, *INTERNAL_METADATA_KEYS.map(&:to_sym))
    end
  end
end

Rails.application.config.to_prepare do
  unless ActiveStorage::DirectUploadsController < ActiveStorageDirectUploadMetadataFilter
    ActiveStorage::DirectUploadsController.prepend(ActiveStorageDirectUploadMetadataFilter)
  end
end
