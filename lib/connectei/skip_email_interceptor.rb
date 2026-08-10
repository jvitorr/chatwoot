# Connectei — ver modifications/016.
#
# Bloqueia entrega para endereços de identidade do ERP.
#
# O ERP provisiona cada atendente com um e-mail sintético e determinístico
# (`store_<loja>_<funcionario>_skipemail@...`): ele existe só como chave da
# identidade no provedor, não como caixa postal de ninguém. O gerenciamento é
# 100% no ERP — o atendente nunca precisa abrir o painel do provedor.
#
# Sem este guarda, cada atribuição de conversa dispara e-mail de notificação
# para um endereço que não existe. O resultado é bounce em série no servidor
# SMTP, o que suja a reputação do domínio de envio e pode fazer o provedor de
# e-mail passar a rejeitar as mensagens que IMPORTAM (as que vão para o
# cliente final).
#
# Um interceptor foi escolhido por ser o ponto de estrangulamento único de
# TODA saída de e-mail do Rails: qualquer mailer, atual ou futuro, passa por
# aqui. Filtrar mailer a mailer deixaria o próximo mailer descoberto.
# O arquivo vive em lib/ (fora do autoload do Zeitwerk) e é carregado por
# `require` no initializer, então o namespace precisa existir antes da classe.
module Connectei; end

class Connectei::SkipEmailInterceptor
  MARKER = 'skipemail'.freeze

  class << self
    def delivering_email(message)
      blocked = extract_blocked(message)
      return if blocked.empty?

      strip_recipients(message)

      # Sobrou destinatário legítimo? Entrega para eles e descarta o resto.
      # Nenhum? Cancela — mandar mensagem sem destinatário é erro de SMTP.
      message.perform_deliveries = false if all_recipients(message).empty?

      Rails.logger.info(
        "[connectei] e-mail de identidade do ERP descartado: #{blocked.size} destinatário(s), assunto=#{message.subject}"
      )
    end

    private

    def all_recipients(message)
      Array(message.to) + Array(message.cc) + Array(message.bcc)
    end

    def extract_blocked(message)
      all_recipients(message).select { |address| blocked?(address) }
    end

    def blocked?(address)
      address.to_s.downcase.include?(MARKER)
    end

    def strip_recipients(message)
      message.to = keep(message.to)
      message.cc = keep(message.cc)
      message.bcc = keep(message.bcc)
    end

    def keep(addresses)
      kept = Array(addresses).reject { |address| blocked?(address) }
      kept.empty? ? nil : kept
    end
  end
end
