class RoomChannel < ApplicationCable::Channel
  def subscribed
    # TODO: should we only do ensure stream  if current account is present?
    # for now going ahead with guard clauses in update_subscription and broadcast_presence
    current_user
    current_account
    ensure_stream
    update_subscription
    broadcast_presence
  # Connectei — ver modifications/013. Sem este rescue, uma identificação que
  # falha aqui vira apenas uma linha de log: ActionCable engole a exceção em
  # Connection::Subscriptions#execute_command e o cliente NÃO recebe nem
  # confirm_subscription nem reject_subscription. O socket fica aberto
  # recebendo só heartbeat, e quem depende do canal degrada em silêncio.
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.warn("[RoomChannel] subscription rejected: #{e.class} - #{e.message}")
    reject
  end

  def update_presence
    update_subscription
    broadcast_presence
  end

  private

  def broadcast_presence
    return if @current_account.blank?

    data = { account_id: @current_account.id, users: ::OnlineStatusTracker.get_available_users(@current_account.id) }
    data[:contacts] = ::OnlineStatusTracker.get_available_contacts(@current_account.id) if @current_user.is_a? User
    ActionCable.server.broadcast(pubsub_token, { event: 'presence.update', data: data })
  end

  def ensure_stream
    stream_from pubsub_token
    stream_from "account_#{@current_account.id}" if @current_account.present? && @current_user.is_a?(User)
  end

  def update_subscription
    return if @current_account.blank?

    ::OnlineStatusTracker.update_presence(@current_account.id, @current_user.class.name, @current_user.id)
  end

  def pubsub_token
    @pubsub_token ||= params[:pubsub_token]
  end

  # Connectei — ver modifications/013: sem `user_id` o upstream assume que o
  # token é de contato e falha para token de agente. Como o token já é único e
  # secreto, resolvemos o agente por ele quando nenhum contato casar — assim
  # `{channel, pubsub_token}` basta para assinar, sem expor ids no cliente.
  def current_user
    @current_user ||= if params[:user_id].present?
                        User.find_by!(pubsub_token: pubsub_token, id: params[:user_id])
                      else
                        ContactInbox.find_by(pubsub_token: pubsub_token)&.contact ||
                          User.find_by!(pubsub_token: pubsub_token)
                      end
  end

  def current_account
    return if current_user.blank?

    @current_account ||= if @current_user.is_a? Contact
                           @current_user.account
                         else
                           resolve_user_account
                         end
  end

  # Connectei — ver modifications/013: `account_id` continua sendo respeitado
  # quando enviado; sem ele, um agente de conta única assina do mesmo jeito em
  # vez de quebrar (`accounts.find(nil)` levantava RecordNotFound).
  def resolve_user_account
    return @current_user.accounts.find(params[:account_id]) if params[:account_id].present?

    accounts = @current_user.accounts
    accounts.first if accounts.count == 1
  end
end
