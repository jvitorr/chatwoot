class Api::V1::Accounts::Instagram::ChannelsController < Api::V1::Accounts::BaseController
  # POST /api/v1/accounts/:account_id/instagram/channels
  #
  # Creates a Channel::Instagram + Inbox using pre-fetched Instagram tokens.
  # Mirrors what Instagram::CallbacksController#create_channel_with_inbox does,
  # but without requiring the OAuth redirect via /instagram/callback. The caller
  # (e.g. an external app) performs the OAuth flow itself, exchanges the code
  # for a long-lived token, and posts the resulting credentials here.
  def create
    validate_create_params!

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

  # PATCH /api/v1/accounts/:account_id/instagram/channels/:id
  #
  # Reconfigure an existing Channel::Instagram by replacing its access_token
  # and expires_at. Use after a fresh OAuth flow to refresh credentials
  # without creating a duplicate channel. Also resets the reauthorization
  # flag and re-subscribes the webhook with the new token.
  def update
    validate_update_params!

    @channel = Channel::Instagram.find_by!(id: params[:id], account_id: Current.account.id)

    expires_at = Time.current + params[:expires_in].to_i.seconds

    @channel.update!(
      access_token: params[:access_token],
      expires_at: expires_at
    )

    @channel.reauthorized! if @channel.respond_to?(:reauthorized!)
    @channel.subscribe if @channel.respond_to?(:subscribe)

    @inbox = @channel.inbox

    render json: {
      success: true,
      id: @inbox&.id,
      channel_id: @channel.id,
      name: @inbox&.name,
      channel_type: 'Channel::Instagram',
      instagram_id: @channel.instagram_id,
      expires_at: @channel.expires_at&.iso8601
    }
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, error: 'Instagram channel not found' }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  rescue ArgumentError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "[Instagram::ChannelsController#update] #{e.class}: #{e.message}"
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def validate_create_params!
    missing = []
    missing << 'access_token' if params[:access_token].blank?
    missing << 'instagram_id' if params[:instagram_id].blank?
    missing << 'username'     if params[:username].blank?
    missing << 'expires_in'   if params[:expires_in].blank? || params[:expires_in].to_i <= 0

    raise ArgumentError, "Missing required parameters: #{missing.join(', ')}" if missing.any?
  end

  def validate_update_params!
    missing = []
    missing << 'access_token' if params[:access_token].blank?
    missing << 'expires_in'   if params[:expires_in].blank? || params[:expires_in].to_i <= 0

    raise ArgumentError, "Missing required parameters: #{missing.join(', ')}" if missing.any?
  end
end
