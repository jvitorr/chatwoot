###############
# [FORK CONNECTEI] modifications/008-filtro-ruido-scanners-axiom.md
#
# Scanners varrendo o servidor (/wp-*, *.php, /.env) geram
# ActionController::RoutingError, que o ActionDispatch::DebugExceptions loga em
# severidade FATAL. O middleware de excecoes (AxiomCaptureExceptions) ja ignora
# RoutingError; este filtro fecha o caminho dos LOGS (Rails.logger.broadcast_to
# -> Axiom::LogDevice), que enviava ~687 "fatais"/dia ao Axiom, envenenando
# alertas por severidade e consumindo cota de ingestao. O access log do proxy
# continua registrando os 404.
############

class Axiom::LogNoiseFilter
  NOISE_PATTERNS = [
    /ActionController::RoutingError \(No route matches/
  ].freeze

  def self.noise?(event)
    message = event.is_a?(Hash) ? (event[:message] || event['message']).to_s : event.to_s
    NOISE_PATTERNS.any? { |pattern| pattern.match?(message) }
  end
end
