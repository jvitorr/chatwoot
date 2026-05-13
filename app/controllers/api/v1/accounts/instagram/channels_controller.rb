class Api::V1::Accounts::Instagram::ChannelsController < Api::V1::Accounts::BaseController
  # POST /api/v1/accounts/:account_id/instagram/channels
  #
  # Creates a Channel::Instagram + Inbox using pre-fetched Instagram tokens.
  # Mirrors what Instagram::CallbacksController#create_channel_with_inbox does,
  # but without requiring the OAuth redirect via /instagram/callback. The caller
  # (e.g. an external app) performs the OAuth flow itself, exchanges the code
  # for a long-lived token, and posts the resulting credentials here.
  def create
    validate_params!

    expires_at = Time.current + params[:expires_in].to_i.seconds

    ActiveRecord::Base.transaction do
      @channel = Channel::Instagram.create!(
        access_token: params[:access_token],
        instagram_id: params[:instagram_id].to_s,
        account: Current.account,
        expires_at: expires_at
      )

      @inbox = Current.account.inboxes.create!(
        channel: @channel,
        name: params[:username]
      )
    end

    render json: {
      success: true,
      id: @inbox.id,
      channel_id: @channel.id,
      name: @inbox.name,
      channel_type: 'Channel::Instagram',
      instagram_id: @channel.instagram_id
    }
  rescue ActiveRecord::RecordNotUnique
    render json: {
      success: false,
      error: 'This Instagram account is already connected to an inbox.'
    }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "[Instagram::ChannelsController#create] #{e.class}: #{e.message}"
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def validate_params!
    missing = []
    missing << 'access_token' if params[:access_token].blank?
    missing << 'instagram_id' if params[:instagram_id].blank?
    missing << 'username'     if params[:username].blank?
    missing << 'expires_in'   if params[:expires_in].blank? || params[:expires_in].to_i <= 0

    raise ArgumentError, "Missing required parameters: #{missing.join(', ')}" if missing.any?
  end
end
