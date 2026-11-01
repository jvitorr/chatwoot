# [FORK CONNECTEI] modifications/025-envio-entrada-e-erro-instagram.md
#
# Aplicada com `prepend` em `Messages::Instagram::MessageBuilder` (Instagram Login).
#
# A busca da story mencionada E o download da mídia rodam DENTRO da transação
# que cria a mensagem (`BaseMessageBuilder#perform`). Uma resposta de erro da
# Graph já era tratada, mas uma exceção de transporte (timeout, conexão recusada)
# subia, desfazia a transação e a menção sumia — inclusive o `ig_event` gravado
# no INSERT, que é o que dispara a automação no ERP.
#
# - Busca da story: a exceção de transporte vira "sem dados da story": a
#   mensagem fica, com o anexo e o marcador, sem `image_type`/`story_id`.
# - Download da mídia (menção, publicação/reel compartilhado): o arquivo é um
#   link da CDN da Meta que expira; 404, conexão recusada ou timeout deixam o
#   anexo só com o `external_url`, e a mensagem fica. O EVENTO importa mais que
#   a imagem. Mídia que o próprio cliente manda (foto, áudio, vídeo) segue o
#   upstream.
module Connectei::Instagram::StoryFetchGuard
  TRANSPORT_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, IOError, OpenSSL::SSL::SSLError,
    # Erro da Graph com corpo que não é JSON (502 de proxy): o upstream faz
    # `JSON.parse(response.body)` no tratamento do erro e levantaria aqui também.
    JSON::ParserError
  ].freeze
  # `Down::Error` cobre 4xx/5xx da CDN, timeout e conexão recusada do download.
  DOWNLOAD_ERRORS = [Down::Error, *TRANSPORT_ERRORS].freeze
  # Tipos (já normalizados pelo builder) cujo arquivo é um link da Meta.
  META_HOSTED_ATTACHMENT_TYPES = %w[story_mention share ig_post ig_reel ig_story].freeze

  def attach_file(attachment, file_url)
    super
  rescue *DOWNLOAD_ERRORS => e
    raise unless META_HOSTED_ATTACHMENT_TYPES.include?(attachment.file_type.to_s)

    Rails.logger.warn("[CONNECTEI][ig-story] mídia #{attachment.file_type} da mensagem #{attachment.message_id} não baixou " \
                      "(#{e.class}); mensagem mantida só com o link")
    nil
  end

  private

  def get_story_object_from_source_id(source_id)
    super
  rescue *TRANSPORT_ERRORS => e
    Rails.logger.warn("[CONNECTEI][ig-story] busca da story #{source_id} falhou (#{e.class}); mensagem mantida sem os dados da story")
    nil
  end
end
