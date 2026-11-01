# [FORK CONNECTEI] modifications/026-endpoints-connectei-instagram.md
#
# Aplicada com `prepend` em `Messages::Instagram::BaseMessageBuilder`: o DM pega o
# MESMO advisory lock `(inbox_id, igsid)` do `comment-threads` antes de procurar
# ou criar a conversa. O builder já roda dentro de uma transação
# (`BaseMessageBuilder#perform`), então o lock vale até o COMMIT da mensagem —
# um comentário e um DM simultâneos da mesma pessoa não abrem duas conversas.
module Connectei::Instagram::ThreadLockExtension
  private

  def set_conversation_based_on_inbox_config
    Connectei::Instagram::ThreadLock.acquire!(@inbox.id, message_source_id)
    super
  end
end
