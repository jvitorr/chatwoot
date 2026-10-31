# Endpoints do Instagram para o ERP Connectei — ver modifications/026.
#
# Base: /api/v1/accounts/:account_id/connectei-instagram/inboxes/:inbox_id
# (contrato fork↔ERP §2). Autenticação: o mesmo `api_access_token` das outras
# chamadas do ERP; token de bot não entra (não está em BOT_ACCESSIBLE_ENDPOINTS).
#
# Isolamento: o inbox tem que ser da conta, do tipo `Channel::Instagram` e
# acessível ao usuário do token (administrador ou membro do inbox). Fora disso a
# resposta é 404 — o mesmo para "não existe" e "não é seu", para não vazar a
# existência de inbox de outra conta.
#
# Erros sempre no formato §2.1: { "error": { kind, code, subcode, message, retry_after } }.
class Api::V1::Accounts::ConnecteiInstagramController < Api::V1::Accounts::BaseController
  ID_FORMAT = /\A[0-9A-Za-z_-]{1,64}\z/
  USERNAME_FORMAT = /\A[0-9A-Za-z_.]{1,100}\z/
  CURSOR_FORMAT = /\A[0-9A-Za-z_=-]{1,512}\z/
  MEDIA_FIELDS = 'id,caption,media_type,media_product_type,permalink,thumbnail_url,media_url,timestamp'.freeze
  USER_FIELDS = 'name,username,is_user_follow_business,is_business_follow_user'.freeze
  REPLY_FIELDS = 'id,text,from,timestamp'.freeze
  USER_KEYS = %w[id username name is_user_follow_business is_business_follow_user].freeze
  REPLY_KEYS = %w[id text from timestamp].freeze
  MAX_PUBLIC_REPLY_LENGTH = 2200
  DEFAULT_MEDIA_LIMIT = 24
  MAX_MEDIA_LIMIT = 100

  rescue_from Connectei::Instagram::GraphClient::Error, with: :render_connectei_error
  rescue_from Connectei::Instagram::ThreadLock::Busy, with: :render_thread_busy

  before_action :set_instagram_inbox
  before_action :ensure_channel_authorized, except: :comment_threads

  # POST comment-threads
  def comment_threads
    render json: Connectei::Instagram::CommentThreadService.new(
      inbox: @inbox,
      igsid: required_id(:igsid),
      username: valid_username,
      comment_id: optional_id(:comment_id)
    ).perform
  end

  # POST comments/:comment_id/replies — resposta pública ao comentário.
  def create_comment_reply
    body = graph.post("#{required_id(:comment_id)}/replies", query: { message: public_reply_message }, rate_limited: true)
    render json: { id: body['id'] }
  end

  # GET comments/:comment_id/replies — releitura que resolve um `ambiguous`. Só as
  # respostas DA PRÓPRIA CONTA: o ERP confere se a resposta pública dele saiu, e um
  # comentário de outra pessoa com o mesmo texto não pode contar como entrega.
  def comment_replies
    body = graph.get("#{required_id(:comment_id)}/replies", query: { fields: REPLY_FIELDS, limit: 50 })
    own_id = @inbox.channel.instagram_id.to_s
    own = Array(body['data']).select { |reply| own_id.present? && reply.dig('from', 'id').to_s == own_id }
    render json: { data: own.map { |reply| reply.slice(*REPLY_KEYS) } }
  end

  # GET media?limit=24&after=<cursor>
  def media
    body = graph.get('me/media', query: media_query)
    render json: { data: Array(body['data']), paging: { after: next_cursor(body) } }
  end

  # GET media/:media_id
  def media_item
    render json: graph.get(required_id(:media_id), query: { fields: MEDIA_FIELDS })
  end

  def ice_breakers
    body = graph.get('me/messenger_profile', query: { fields: 'ice_breakers', platform: 'instagram' })
    render json: { ice_breakers: Connectei::Instagram::IceBreakers.from_graph(body) }
  end

  def update_ice_breakers
    items = Connectei::Instagram::IceBreakers.validate!(params[:ice_breakers])
    graph.post('me/messenger_profile', json: { platform: 'instagram', ice_breakers: Connectei::Instagram::IceBreakers.to_graph(items) })
    render json: { ice_breakers: items }
  end

  def destroy_ice_breakers
    graph.delete('me/messenger_profile', query: { fields: '["ice_breakers"]', platform: 'instagram' })
    render json: { ice_breakers: [] }
  end

  # GET users/:igsid — "segue a loja?" (409 quando a pessoa nunca mandou DM).
  def user
    render json: graph.get(required_id(:igsid), query: { fields: USER_FIELDS }).slice(*USER_KEYS)
  end

  private

  def set_instagram_inbox
    @inbox = Current.account.inboxes.find_by(id: params[:inbox_id])
    return if @inbox&.channel.is_a?(Channel::Instagram) && Current.user.assigned_inboxes.exists?(id: @inbox.id)

    render_connectei_error(Connectei::Instagram::GraphClient::Error.new(kind: :not_found, http_status: 404, message: 'Instagram inbox not found'))
  end

  # Token já sabidamente inválido: não insiste na Graph.
  def ensure_channel_authorized
    return unless @inbox.channel.reauthorization_required?

    render_connectei_error(Connectei::Instagram::GraphClient::Error.new(
                             kind: :reauthorization_required, http_status: 403, message: 'Instagram channel needs to be reconnected'
                           ))
  end

  def graph
    @graph ||= Connectei::Instagram::GraphClient.new(@inbox.channel)
  end

  # O id vai para o caminho da URL da Graph: só caracteres de id.
  def required_id(name)
    value = params[name].to_s
    return value if value.match?(ID_FORMAT)

    raise Connectei::Instagram::GraphClient::Error.invalid("#{name} inválido")
  end

  def optional_id(name)
    params[name].present? ? required_id(name) : nil
  end

  def valid_username
    username = params[:username].to_s.strip.delete_prefix('@')
    return if username.blank?
    return username if username.match?(USERNAME_FORMAT)

    raise Connectei::Instagram::GraphClient::Error.invalid('username inválido')
  end

  def public_reply_message
    message = params[:message]
    return message if message.is_a?(String) && message.strip.present? && message.length <= MAX_PUBLIC_REPLY_LENGTH

    raise Connectei::Instagram::GraphClient::Error.invalid("message deve ter de 1 a #{MAX_PUBLIC_REPLY_LENGTH} caracteres")
  end

  def media_query
    query = { fields: MEDIA_FIELDS, limit: media_limit }
    return query if params[:after].blank?
    raise Connectei::Instagram::GraphClient::Error.invalid('after inválido') unless params[:after].to_s.match?(CURSOR_FORMAT)

    query.merge(after: params[:after].to_s)
  end

  def media_limit
    return DEFAULT_MEDIA_LIMIT if params[:limit].blank?

    limit = Integer(params[:limit].to_s, 10)
    return limit if limit.between?(1, MAX_MEDIA_LIMIT)

    raise ArgumentError
  rescue ArgumentError
    raise Connectei::Instagram::GraphClient::Error.invalid("limit deve ser um inteiro de 1 a #{MAX_MEDIA_LIMIT}")
  end

  # Só há próxima página quando a Graph manda `paging.next`.
  def next_cursor(body)
    body.dig('paging', 'next').present? ? body.dig('paging', 'cursors', 'after') : nil
  end

  def render_connectei_error(error)
    response.set_header('Retry-After', error.retry_after.to_s) if error.kind == :rate_limited && error.retry_after
    render json: error.as_json, status: error.http_status
  end

  def render_thread_busy(exception)
    render_connectei_error(Connectei::Instagram::GraphClient::Error.new(kind: :unavailable, http_status: 503, message: exception.message,
                                                                        retry_after: 1))
  end
end
