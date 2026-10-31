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
    create_channel_with_inbox!

    render json: create_response
  rescue ActiveRecord::RecordNotUnique
    render json: { success: false, error: 'This Instagram account is already connected to an inbox.' },
           status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
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
  #
  # [FORK CONNECTEI] modifications/024: `granted_scopes` (opcional, no POST e no
  # PATCH) grava os escopos concedidos no OAuth. Eles decidem se o webhook assina
  # `comments`. No PATCH, ausente = mantém o que estava; presente (mesmo vazio) =
  # substitui.
  def update
    validate_update_params!
    find_and_update_channel!

    render json: update_response
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, error: 'Instagram channel not found' }, status: :not_found
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "[Instagram::ChannelsController#update] #{e.class}: #{e.message}"
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def create_channel_with_inbox!
    expires_at = Time.current + params[:expires_in].to_i.seconds

    ActiveRecord::Base.transaction do
      @channel = Channel::Instagram.create!(
        access_token: params[:access_token],
        instagram_id: params[:instagram_id].to_s,
        account: Current.account,
        expires_at: expires_at,
        connectei_granted_scopes: granted_scopes_param || []
      )

      @inbox = Current.account.inboxes.create!(channel: @channel, name: params[:username])
    end
  end

  def find_and_update_channel!
    @channel = Channel::Instagram.find_by!(id: params[:id], account_id: Current.account.id)
    expires_at = Time.current + params[:expires_in].to_i.seconds

    attributes = { access_token: params[:access_token], expires_at: expires_at }
    attributes[:connectei_granted_scopes] = granted_scopes_param if params.key?(:granted_scopes)
    @channel.update!(attributes)

    @channel.reauthorized! if @channel.respond_to?(:reauthorized!)
    @channel.subscribe if @channel.respond_to?(:subscribe)

    @inbox = @channel.inbox
  end

  def create_response
    {
      success: true,
      id: @inbox.id,
      channel_id: @channel.id,
      name: @inbox.name,
      channel_type: 'Channel::Instagram',
      instagram_id: @channel.instagram_id,
      granted_scopes: @channel.connectei_granted_scopes
    }
  end

  def update_response
    {
      success: true,
      id: @inbox&.id,
      channel_id: @channel.id,
      name: @inbox&.name,
      channel_type: 'Channel::Instagram',
      instagram_id: @channel.instagram_id,
      expires_at: @channel.expires_at&.iso8601,
      granted_scopes: @channel.connectei_granted_scopes
    }
  end

  # Lista ou texto separado por vírgula; `nil` quando o parâmetro não veio.
  def granted_scopes_param
    return unless params.key?(:granted_scopes)

    Connectei::Instagram::SubscribedFields.normalize_scopes(params[:granted_scopes])
  end

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
