# [FORK CONNECTEI] modifications/025-envio-entrada-e-erro-instagram.md
#
# Aplicada com `prepend` em `Messages::Instagram::BaseMessageBuilder`: junta os
# atributos de `Connectei::Instagram::InboundAttributes` (ig_event, quick reply,
# postback, referral) ao `content_attributes` do INSERT da mensagem — antes de o
# builder processar anexos e buscar a story na Graph.
module Connectei::Instagram::InboundAttributesExtension
  private

  def message_params
    params = super
    params[:content_attributes] = params[:content_attributes].merge(Connectei::Instagram::InboundAttributes.extract(@messaging))
    params
  end
end
