# [FORK CONNECTEI] modifications/026-endpoints-connectei-instagram.md
#
# Exclusão mútua na criação de contato/conversa de um IGSID num inbox Instagram.
#
# São dois locks, porque são dois riscos:
#
# 1. `with_message_mutex` — o MESMO mutex do `Webhooks::InstagramEventsJob`
#    (`IG_MESSAGE_CREATE_LOCK::<igsid>::<ig_account_id>`, Redis, TTL de 3s). Faz o
#    `comment-threads` esperar um DM em processamento daquele contato (e vice-versa).
#    É curto e sem garantia forte: o job do upstream, depois de 3 tentativas,
#    processa sem o lock.
# 2. `acquire!` — advisory lock transacional do Postgres em `(inbox_id, igsid)`.
#    Esse é o que garante: o `comment-threads` e o builder de mensagens do
#    Instagram (via `ThreadLockExtension`) pegam o mesmo lock DENTRO da transação
#    que procura/cria a conversa. Quem chega depois espera o COMMIT do primeiro e
#    então enxerga a conversa dele — nunca nascem duas.
module Connectei::Instagram::ThreadLock
  MUTEX_TTL = 3.seconds
  MUTEX_WAIT = 5.seconds
  MUTEX_POLL_INTERVAL = 0.05

  class Busy < StandardError; end

  module_function

  def acquire!(inbox_id, source_id)
    sql = ActiveRecord::Base.sanitize_sql_array(['SELECT pg_advisory_xact_lock(?)', advisory_key(inbox_id, source_id)])
    ActiveRecord::Base.connection.execute(sql)
  end

  # Inteiro de 64 bits com sinal, estável para o par (inbox, igsid).
  def advisory_key(inbox_id, source_id)
    Digest::SHA256.digest("connectei:ig-thread:#{inbox_id}:#{source_id}")[0, 8].unpack1('q>')
  end

  # Espera o mutex do job de eventos por até MUTEX_WAIT (ele dura no máximo
  # MUTEX_TTL) e o libera só se ainda for o dono.
  def with_message_mutex(source_id, ig_account_id)
    key = format(::Redis::Alfred::IG_MESSAGE_MUTEX, sender_id: source_id, ig_account_id: ig_account_id)
    token = SecureRandom.hex(12)
    raise Busy, "lock #{key} não liberou em #{MUTEX_WAIT.to_i}s" unless wait_for_mutex(key, token)

    begin
      yield
    ensure
      ::Redis::Alfred.delete_if_equals(key, token)
    end
  end

  def wait_for_mutex(key, token)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MUTEX_WAIT
    loop do
      return true if ::Redis::Alfred.set(key, token, nx: true, ex: MUTEX_TTL.to_i)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep(MUTEX_POLL_INTERVAL)
    end
  end
end
