module Telegram::AttachmentHandling
  private

  def file_content_type
    return :image if image_message?
    return :audio if audio_message?
    return :video if video_message?

    file_type(params[:message][:document][:mime_type])
  end

  def image_message?
    params[:message][:photo].present? || params.dig(:message, :sticker, :thumb).present?
  end

  def audio_message?
    params[:message][:voice].present? || params[:message][:audio].present?
  end

  def video_message?
    params[:message][:video].present? || params[:message][:video_note].present?
  end

  def attach_files
    return unless file

    file_download_path = telegram_file_download_path
    return unless file_download_path

    SafeFetch.fetch(file_download_path, allowed_content_types: Attachment::ACCEPTABLE_FILE_TYPES) do |attachment_file|
      build_file_attachment(attachment_file)
    end
  rescue SafeFetch::Error => e
    Rails.logger.info "Error downloading Telegram attachment from #{file_download_path}: #{e.message}: Skipping"
  end

  def telegram_file_download_path
    file_download_path = inbox.channel.get_telegram_file_path(file[:file_id])
    return file_download_path if file_download_path.present?

    Rails.logger.info "Telegram file download path is blank for #{file[:file_id]} : inbox_id: #{inbox.id}"
    nil
  end

  def build_file_attachment(attachment_file)
    track_downloaded_file(attachment_file)
    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_content_type,
      file: {
        io: attachment_file.tempfile,
        filename: attachment_file.original_filename,
        content_type: attachment_file.content_type
      }
    )
  end

  def file
    @file ||= visual_media_params || params[:message][:voice].presence || params[:message][:audio].presence || params[:message][:document].presence
  end

  def location_fallback_title
    return '' if venue.blank?

    venue[:title] || ''
  end

  def venue
    @venue ||= params.dig(:message, :venue).presence
  end

  def visual_media_params
    params[:message][:photo].presence&.last ||
      params.dig(:message, :sticker, :thumb).presence ||
      params[:message][:video].presence ||
      params[:message][:video_note].presence
  end
end
