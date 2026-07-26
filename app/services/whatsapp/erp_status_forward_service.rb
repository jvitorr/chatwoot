# Entrega ao Connectei (ERP) os eventos de status de mensagens que não pertencem
# ao Chatwoot. Ver `Whatsapp::ForwardMessageStatusToErpJob` para o porquê deste
# caminho existir.
#
# AUTENTICAÇÃO
# HMAC-SHA256 sobre `<timestamp>.<corpo>`, no cabeçalho `x-connectei-signature`,
# formato `t=<epoch>,v1=<hex>`. O timestamp entra no material assinado para que
# um repasse capturado não possa ser renovado trocando só o `t=`; o ERP recusa
# fora de uma janela curta.
#
# Não dá para reencaminhar a assinatura original da Meta: o HMAC dela é sobre os
# bytes exatos recebidos, e esses bytes não sobrevivem ao `params.to_unsafe_hash`
# do controller nem à serialização do ActiveJob. O limite de confiança do ERP
# passa a ser o Chatwoot — o que já era verdade de fato, já que o Chatwoot é o
# dono do canal.
class Whatsapp::ErpStatusForwardService
  # Aninhada na classe de propósito: o Zeitwerk resolve constantes pelo nome do
  # arquivo, então um `Whatsapp::ErpStatusForwardError` solto exigiria um
  # arquivo próprio. Mesmo padrão de `MutexApplicationJob::LockAcquisitionError`.
  class Error < StandardError; end

  SIGNATURE_HEADER = 'x-connectei-signature'.freeze
  REQUEST_TIMEOUT_SECONDS = 10

  def initialize(statuses)
    @statuses = statuses
  end

  def perform
    return unless configured?

    body = { statuses: @statuses }.to_json
    timestamp = Time.now.to_i

    response = HTTParty.post(
      endpoint_url,
      headers: {
        'Content-Type' => 'application/json',
        SIGNATURE_HEADER => signature_for(body, timestamp)
      },
      body: body,
      timeout: REQUEST_TIMEOUT_SECONDS
    )

    handle_response(response)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    # Falha de rede é transitória: deixa o job retentar.
    raise Error, "ERP unreachable: #{e.message}"
  end

  private

  # Sem configuração o repasse é desligado, e isso é intencional: uma instância
  # que não integra com o ERP precisa funcionar normalmente. Mas silêncio total
  # é ruim de diagnosticar — quem investiga "o status não chega ao ERP" precisa
  # ver a causa no log, e não concluir que o gancho não foi chamado.
  #
  # Log em nível `info` e apenas uma vez por execução: isto roda por evento de
  # status, então `warn` a cada mensagem transformaria o log em ruído.
  def configured?
    return true if endpoint_url.present? && secret.present?

    faltando = []
    faltando << 'CONNECTEI_STATUS_FORWARD_URL' if endpoint_url.blank?
    faltando << 'CONNECTEI_STATUS_FORWARD_SECRET' if secret.blank?
    Rails.logger.info(
      "[WHATSAPP][erp-status-forward] repasse desativado: #{faltando.join(', ')} não configurado(s). " \
      'O processamento do webhook segue normalmente.'
    )
    false
  end

  def handle_response(response)
    return if response.success?

    # 4xx é contrato quebrado (assinatura, corpo): insistir não resolve, então
    # só registra. 5xx é indisponibilidade: levanta para o job retentar.
    raise Error, "ERP responded #{response.code}: #{response.body}" if response.code >= 500

    Rails.logger.error(
      "[WHATSAPP][erp-status-forward] ERP rejected forward (#{response.code}): #{response.body}"
    )
  end

  def signature_for(body, timestamp)
    digest = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{body}")
    "t=#{timestamp},v1=#{digest}"
  end

  def endpoint_url
    @endpoint_url ||= GlobalConfigService.load('CONNECTEI_STATUS_FORWARD_URL', ENV.fetch('CONNECTEI_STATUS_FORWARD_URL', nil))
  end

  def secret
    @secret ||= GlobalConfigService.load('CONNECTEI_STATUS_FORWARD_SECRET', ENV.fetch('CONNECTEI_STATUS_FORWARD_SECRET', nil))
  end
end
