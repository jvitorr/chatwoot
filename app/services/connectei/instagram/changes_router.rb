# [FORK CONNECTEI] modifications/024-repasse-de-eventos-instagram-ao-erp.md
#
# Desvia do `Webhooks::InstagramEventsJob` os eventos do Instagram que NÃO são
# mensagem — comentário e referral solto — e os repassa ao ERP (contrato §1).
#
# O DEFEITO QUE ISTO CORRIGE
# O job tratava toda entrada com `changes` como "evento de teste" da Meta
# (`test_event? = entry[:changes].present?`). Um comentário real chegava ao
# `Instagram::TestEventService`, que lê `value[:sender][:id]` — e comentário não
# tem `sender`. O `NoMethodError` derrubava o job, o Sidekiq reprocessava o lote
# inteiro a cada tentativa, e os DMs que viessem DEPOIS do comentário no mesmo
# lote nunca eram processados.
#
# CONTRATO COM O JOB
# `route(entry)` devolve `true` quando a entrada era um evento real de
# `changes[]` / `field-value`: ela já foi tratada aqui e o job não segue nem para
# o teste da Meta nem para mensagens. Devolve `false` para todo o resto — inclusive
# o evento de teste da Meta (`field: 'messages'` com sender/recipient), que
# continua no `TestEventService`. Nunca levanta: um erro aqui não pode derrubar o
# lote, que é justamente o defeito acima.
class Connectei::Instagram::ChangesRouter
  COMMENTS_FIELD = 'comments'.freeze
  META_TEST_FIELD = 'messages'.freeze
  LOG_PREFIX = '[CONNECTEI][ig-changes]'.freeze

  def self.route(entry)
    new(entry).route
  end

  # Lote em que nenhuma entrada traz `messaging`/`standby`: não há contato, e o
  # mutex por contato do job não protege nada (só faria rajada de comentários da
  # mesma conta disputar uma chave vazia).
  def self.without_messaging?(entries)
    entries = Array(entries)
    entries.present? && entries.all? do |entry|
      entry = entry.to_h.with_indifferent_access
      entry[:messaging].blank? && entry[:standby].blank?
    end
  end

  def initialize(entry)
    @entry = entry.to_h.with_indifferent_access
  end

  def route
    forward_standalone_referrals
    return false unless real_changes_entry?

    changes.each { |change| safely { route_change(change) } }
    true
  end

  private

  def changes
    @changes ||= if @entry[:changes].is_a?(Array)
                   @entry[:changes].select { |change| change.is_a?(Hash) }.map(&:with_indifferent_access)
                 elsif @entry[:field].present?
                   [{ field: @entry[:field], value: @entry[:value] }.with_indifferent_access]
                 else
                   []
                 end
  end

  def real_changes_entry?
    changes.present? && !meta_test_event?
  end

  # O formato do painel de desenvolvedor da Meta: `changes[]` com `field: messages`
  # e um `value` no formato de mensagem. Só esse vai para o TestEventService.
  def meta_test_event?
    @entry[:changes].is_a?(Array) && changes.any? do |change|
      change[:field] == META_TEST_FIELD &&
        change.dig(:value, :sender, :id).present? && change.dig(:value, :recipient, :id).present?
    end
  end

  def route_change(change)
    return forward_comment(change[:value]) if change[:field] == COMMENTS_FIELD

    # `live_comments` está fora de escopo; o resto (mentions, story_insights…) o
    # fork não assina. Registra para quem investigar um campo novo da Meta.
    Rails.logger.info("#{LOG_PREFIX} campo '#{change[:field]}' ignorado (instagram_id=#{@entry[:id]})")
  end

  def forward_comment(raw_value)
    value = raw_value.is_a?(Hash) ? raw_value.with_indifferent_access : {}.with_indifferent_access
    comment_id = (value[:id].presence || value[:comment_id].presence)&.to_s
    return skip('comentário sem comment_id') if comment_id.blank?

    channel = channel_for(@entry[:id])
    return skip("comentário #{comment_id}: canal não encontrado") if channel.blank?
    # Resposta pública da própria conta volta como webhook de comentário; repassar
    # criaria o laço resposta pública → webhook → automação → resposta pública.
    return if value.dig(:from, :id).to_s == channel.instagram_id.to_s

    enqueue(Connectei::Instagram::EventPayload.comment(channel: channel, entry: @entry, value: value, comment_id: comment_id))
  end

  # Referral "solto" (`messaging_referral`): o clique num link ig.me com `ref` ou
  # num anúncio, numa conversa que já existe, chega sem mensagem nem postback. O
  # job não tem evento para ele (descartava em silêncio); a origem da campanha
  # (automação #11) depende dele.
  def forward_standalone_referrals
    (array_at(:messaging) + array_at(:standby)).each do |messaging|
      next unless messaging.is_a?(Hash)

      messaging = messaging.with_indifferent_access
      next unless standalone_referral?(messaging)

      safely { forward_referral(messaging) }
    end
  end

  # Cópia: o hash da entrada é do job e não pode ser mutado aqui.
  def array_at(key)
    @entry[key].is_a?(Array) ? @entry[key].dup : []
  end

  def standalone_referral?(messaging)
    messaging[:referral].present? && messaging[:message].blank? && messaging[:postback].blank?
  end

  def forward_referral(messaging)
    sender_id = messaging.dig(:sender, :id).presence
    timestamp = Connectei::Instagram::EventPayload.unix_milliseconds(messaging[:timestamp] || @entry[:time])
    return skip('referral sem sender_id ou timestamp') if sender_id.blank? || timestamp.blank?

    channel = channel_for(messaging.dig(:recipient, :id))
    return skip("referral de #{sender_id}: canal não encontrado") if channel.blank?

    enqueue(Connectei::Instagram::EventPayload.referral(channel: channel, entry: @entry, messaging: messaging, timestamp: timestamp))
  end

  # Só Instagram Login (`Channel::Instagram`): é o canal dos endpoints da mod 026
  # e o único que assina `comments`. Canal sem inbox não tem para onde repassar.
  def channel_for(instagram_id)
    return if instagram_id.blank?

    channel = Channel::Instagram.find_by(instagram_id: instagram_id.to_s)
    channel if channel&.inbox.present?
  end

  def enqueue(payload)
    return unless Connectei::Instagram::EventForwarder.configured?

    Connectei::ForwardInstagramEventJob.perform_later(payload)
  end

  def skip(reason)
    Rails.logger.info("#{LOG_PREFIX} não repassado: #{reason}")
    nil
  end

  def safely
    yield
  rescue StandardError => e
    Rails.logger.error("#{LOG_PREFIX} falha ao repassar evento (instagram_id=#{@entry[:id]}): #{e.class}: #{e.message}")
    ChatwootExceptionTracker.new(e).capture_exception
    nil
  end
end
