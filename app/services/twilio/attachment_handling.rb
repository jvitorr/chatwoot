module Twilio::AttachmentHandling
  private

  def attach_files
    num_media = params[:NumMedia].to_i
    return if num_media.zero?

    num_media.times do |index|
      media_url = params[:"MediaUrl#{index}"]
      attach_single_file(media_url) if media_url.present?
    end
  end

  def attach_single_file(media_url)
    download_attachment_file(media_url) do |attachment_file|
      track_downloaded_file(attachment_file)
      @message.attachments.new(
        account_id: @message.account_id,
        file_type: file_type(attachment_file.content_type),
        file: {
          io: attachment_file.tempfile,
          filename: attachment_file.original_filename,
          content_type: attachment_file.content_type
        }
      )
    end
  end

  def download_attachment_file(media_url, &)
    download_with_auth(media_url, &)
  rescue SafeFetch::Error => e
    handle_download_attachment_error(e, media_url, &)
  end

  def download_with_auth(media_url, &)
    SafeFetch.fetch(
      media_url,
      http_basic_authentication: attachment_auth_credentials,
      allowed_content_types: Attachment::ACCEPTABLE_FILE_TYPES,
      &
    )
  end

  def attachment_auth_credentials
    return [twilio_channel.api_key_sid, twilio_channel.auth_token] if twilio_channel.api_key_sid.present?

    [twilio_channel.account_sid, twilio_channel.auth_token]
  end

  def handle_download_attachment_error(error, media_url, &)
    Rails.logger.info "Error downloading attachment from Twilio: #{error.message}: Retrying without auth"
    SafeFetch.fetch(media_url, allowed_content_types: Attachment::ACCEPTABLE_FILE_TYPES, &)
  rescue SafeFetch::Error => e
    Rails.logger.info "Error downloading attachment from Twilio: #{e.message}: Skipping"
  end

  def location_message?
    params[:MessageType] == 'location' && params[:Latitude].present? && params[:Longitude].present?
  end

  def attach_location
    @message.attachments.new(
      account_id: @message.account_id,
      file_type: :location,
      coordinates_lat: params[:Latitude].to_f,
      coordinates_long: params[:Longitude].to_f
    )
  end
end
