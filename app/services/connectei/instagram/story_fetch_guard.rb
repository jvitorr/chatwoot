# [FORK CONNECTEI] modifications/025-envio-entrada-e-erro-instagram.md
#
# Aplicada com `prepend` em `Messages::Instagram::MessageBuilder` (Instagram Login).
#
# A busca da story mencionada roda DENTRO da transação que cria a mensagem
# (`BaseMessageBuilder#perform`). Uma resposta de erro da Graph já era tratada, mas
# uma exceção de transporte (timeout, conexão recusada) subia, desfazia a
# transação e a menção sumia — inclusive o `ig_event` gravado no INSERT. Aqui a
# exceção de transporte vira "sem dados da story": a mensagem fica, com o anexo e
# o marcador, sem `image_type`/`story_id`.
module Connectei::Instagram::StoryFetchGuard
  TRANSPORT_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, IOError, OpenSSL::SSL::SSLError,
    # Erro da Graph com corpo que não é JSON (502 de proxy): o upstream faz
    # `JSON.parse(response.body)` no tratamento do erro e levantaria aqui também.
    JSON::ParserError
  ].freeze

  private

  def get_story_object_from_source_id(source_id)
    super
  rescue *TRANSPORT_ERRORS => e
    Rails.logger.warn("[CONNECTEI][ig-story] busca da story #{source_id} falhou (#{e.class}); mensagem mantida sem os dados da story")
    nil
  end
end
