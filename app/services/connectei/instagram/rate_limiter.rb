# [FORK CONNECTEI] modifications/025-envio-entrada-e-erro-instagram.md
#
# Limitador por conta do Instagram, consultado IMEDIATAMENTE antes de cada
# chamada à Graph que entrega algo a uma pessoa (contrato fork↔ERP §5):
#
#   CONNECTEI_IG_SEND_PER_SECOND         padrão  90 (a Send API aceita 100/s por conta)
#   CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR  padrão 720 (a Meta aceita 750/h por conta)
#
# A margem abaixo do teto da Meta existe porque a Meta conta do lado dela, com o
# relógio dela: estourar lá devolve 613/80002 e o ERP perderia o slot.
#
# ALGORITMO
# Janela deslizante de verdade (log de timestamps num ZSET por conta), não janela
# fixa: com janela fixa de 1h, 720 envios às 10:59 e mais 720 às 11:00 passariam —
# 1440 em dois minutos, o dobro do que a Meta aceita.
#
# Cada aquisição, numa transação MULTI: remove o que saiu da janela, ADICIONA a
# própria marca e CONTA. Se a contagem passou do limite, retira a própria marca e
# recusa. Adicionar antes de contar é o que torna a decisão correta sob
# concorrência sem Lua (o MockRedis dos specs não executa EVAL): dois envios
# simultâneos no último slot veem 720 e 721, e só o segundo recua.
#
# Falha-aberto: Redis indisponível não bloqueia envio (registra e libera). Sem
# Redis o Sidekiq também não roda, e bloquear aqui só esconderia a causa.
class Connectei::Instagram::RateLimiter
  Decision = Struct.new(:allowed, :retry_after, :limit_name, keyword_init: true) do
    def allowed?
      allowed
    end
  end

  SEND_ENV = 'CONNECTEI_IG_SEND_PER_SECOND'.freeze
  PRIVATE_REPLY_ENV = 'CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR'.freeze
  DEFAULT_SEND_PER_SECOND = 90
  DEFAULT_PRIVATE_REPLY_PER_HOUR = 720
  KEY_PREFIX = 'CONNECTEI_IG_RATE'.freeze

  # Uma janela deslizante: nome (também na chave), teto e duração.
  Window = Struct.new(:name, :limit, :seconds) do
    def milliseconds
      seconds * 1000
    end
  end

  def self.send_per_second
    positive_env(SEND_ENV, DEFAULT_SEND_PER_SECOND)
  end

  def self.private_reply_per_hour
    positive_env(PRIVATE_REPLY_ENV, DEFAULT_PRIVATE_REPLY_PER_HOUR)
  end

  def self.positive_env(name, default)
    value = Integer(ENV.fetch(name, '').to_s.strip, 10)
    value.positive? ? value : default
  rescue ArgumentError
    default
  end

  def initialize(instagram_id)
    @instagram_id = instagram_id.to_s
  end

  def acquire_send
    acquire(Window.new('send', self.class.send_per_second, 1))
  end

  def acquire_private_reply
    acquire(Window.new('private_reply', self.class.private_reply_per_hour, 1.hour.to_i))
  end

  private

  def acquire(window)
    key = "#{KEY_PREFIX}::#{window.name}::#{@instagram_id}"
    now_ms = (Time.now.to_f * 1000).to_i
    member = "#{now_ms}:#{SecureRandom.hex(6)}"

    Redis::Alfred.with do |conn|
      next Decision.new(allowed: true, limit_name: window.name) if record_and_count(conn, key, member, now_ms, window) <= window.limit

      conn.zrem(key, member)
      Decision.new(allowed: false, retry_after: retry_after(conn, key, now_ms, window), limit_name: window.name)
    end
  rescue StandardError => e
    Rails.logger.error("[CONNECTEI][ig-rate-limit] limitador indisponível (#{window.name}, ig=#{@instagram_id}), " \
                       "liberando: #{e.class}: #{e.message}")
    Decision.new(allowed: true, limit_name: window.name)
  end

  def record_and_count(conn, key, member, now_ms, window)
    results = conn.multi do |transaction|
      transaction.zremrangebyscore(key, 0, now_ms - window.milliseconds)
      transaction.zadd(key, now_ms, member)
      transaction.zcard(key)
      transaction.expire(key, window.seconds + 1)
    end
    results[2].to_i
  end

  # Segundos até a marca mais antiga sair da janela (mínimo 1).
  def retry_after(conn, key, now_ms, window)
    oldest = conn.zrange(key, 0, 0, with_scores: true).first&.last
    return window.seconds if oldest.nil?

    [((oldest.to_f + window.milliseconds - now_ms) / 1000.0).ceil, 1].max
  end
end
