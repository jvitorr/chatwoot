# [FORK CONNECTEI] modifications/026-endpoints-connectei-instagram.md
#
# `POST /connectei-instagram/inboxes/:inbox_id/comment-threads` (contrato fork↔ERP §2.2).
#
# Materializa o contato e a conversa de quem COMENTOU, para o ERP mandar o private
# reply pela API normal de mensagens (o eco e o webhook de conta só existem para
# mensagem que nasce numa conversa daqui).
#
# - Contato: encontrado pelo `source_id = igsid` ou criado com nome = username,
#   `social_instagram_user_name`/`social_profiles.instagram` = username e
#   `connectei_profile_pending = true` — SEM chamar o User Profile da Meta, que
#   exige que a pessoa já tenha mandado DM. O perfil é buscado no primeiro DM
#   (`PendingProfileExtension`), que apaga a marca.
# - Conversa: respeita `lock_to_single_conversation` exatamente como o builder de
#   mensagens do Instagram; sem nenhuma, cria com status `pending` (fora da caixa
#   "abertas"). Nunca muda o status de uma existente e nunca cria mensagem.
# - Locks: `Connectei::Instagram::ThreadLock` (mutex do job de eventos + advisory).
class Connectei::Instagram::CommentThreadService
  def initialize(inbox:, igsid:, username: nil, comment_id: nil)
    @inbox = inbox
    @igsid = igsid.to_s
    @username = username.to_s.delete_prefix('@').presence
    @comment_id = comment_id
  end

  def perform
    contact_inbox, conversation, created = Connectei::Instagram::ThreadLock.with_message_mutex(@igsid, @inbox.channel.instagram_id) do
      ActiveRecord::Base.transaction do
        Connectei::Instagram::ThreadLock.acquire!(@inbox.id, @igsid)
        contact_inbox = find_or_create_contact_inbox
        [contact_inbox, *find_or_create_conversation(contact_inbox)]
      end
    end
    log(conversation, created)
    # Depois do COMMIT: o `display_id` é preenchido por trigger do banco e só é
    # carregado no `after_create_commit` da conversa.
    response(contact_inbox, conversation, created)
  end

  private

  def find_or_create_contact_inbox
    ::ContactInboxWithContactBuilder.new(
      source_id: @igsid,
      inbox: @inbox,
      contact_attributes: { name: @username || "Instagram #{@igsid}", additional_attributes: new_contact_attributes }
    ).perform
  end

  # Só valem quando o contato é CRIADO aqui: contato existente não é tocado.
  def new_contact_attributes
    attributes = { 'connectei_profile_pending' => true }
    return attributes if @username.blank?

    attributes.merge('social_instagram_user_name' => @username, 'social_profiles' => { 'instagram' => @username })
  end

  def find_or_create_conversation(contact_inbox)
    existing = existing_conversation(contact_inbox)
    return [existing, false] if existing

    conversation = Conversation.create!(
      conversation_params(contact_inbox).merge(contact_inbox_id: contact_inbox.id, status: :pending, additional_attributes: {})
    )
    [conversation, true]
  end

  # Mesmo critério de `Messages::Instagram::BaseMessageBuilder#set_conversation_based_on_inbox_config`.
  def existing_conversation(contact_inbox)
    scope = Conversation.where(conversation_params(contact_inbox))
    scope = scope.where.not(status: :resolved) unless @inbox.lock_to_single_conversation
    scope.order(created_at: :desc).first
  end

  def conversation_params(contact_inbox)
    { account_id: @inbox.account_id, inbox_id: @inbox.id, contact_id: contact_inbox.contact_id }
  end

  def response(contact_inbox, conversation, created)
    {
      conversation_id: conversation.display_id || Conversation.where(id: conversation.id).pick(:display_id),
      conversation_status: conversation.status,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id,
      source_id: @igsid,
      created: created
    }
  end

  def log(conversation, created)
    Rails.logger.info("[CONNECTEI][ig-comment-thread] inbox_id=#{@inbox.id} igsid=#{@igsid} comment_id=#{@comment_id} " \
                      "conversation_id=#{conversation.id} created=#{created}")
  end
end
