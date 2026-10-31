# [FORK CONNECTEI] modifications/028-instagram-graph-base-e-renovacao-de-token.md
#
# Ponto único do endereço e dos timeouts da Graph do Instagram (Instagram Login).
#
# ENDEREÇO
# `INSTAGRAM_GRAPH_BASE_URL` troca o host (padrão `https://graph.instagram.com`)
# para o E2E e a carga apontarem o fork para um stub. É lida DIRETO do ambiente,
# de propósito: `GlobalConfigService.load` grava o primeiro valor lido em
# `installation_configs` e, dali em diante, o banco vence a env (a armadilha
# descrita na mod 001). Para um endereço que existe para ser trocado por
# ambiente, isso faria o stub nunca ser usado depois do primeiro boot.
#
# A versão continua vindo de `INSTAGRAM_API_VERSION` pelo `GlobalConfigService`,
# como no upstream (#14937, mod 023).
#
# TIMEOUTS
# Sem timeout explícito o HTTParty usa o padrão do Net::HTTP (60s), que prende uma
# thread do Sidekiq por um minuto quando a Graph trava. 5s para abrir a conexão
# e 15s para ler a resposta (contrato fork↔ERP §2).
module Connectei::Instagram::Graph
  DEFAULT_BASE_URL = 'https://graph.instagram.com'.freeze
  DEFAULT_API_VERSION = 'v22.0'.freeze
  OPEN_TIMEOUT_SECONDS = 5
  READ_TIMEOUT_SECONDS = 15
  TIMEOUTS = { open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS }.freeze

  module_function

  # Host sem versão, sem barra final. Usado pelas rotas que a Meta não versiona
  # (`/refresh_access_token`, `/access_token`).
  def base_url
    ENV.fetch('INSTAGRAM_GRAPH_BASE_URL', nil).presence&.strip&.chomp('/') || DEFAULT_BASE_URL
  end

  def api_version
    GlobalConfigService.load('INSTAGRAM_API_VERSION', DEFAULT_API_VERSION)
  end

  # Host + versão: base de toda chamada versionada (`/{id}/messages`, `/me/media`…).
  def versioned_base_url
    "#{base_url}/#{api_version}"
  end
end
