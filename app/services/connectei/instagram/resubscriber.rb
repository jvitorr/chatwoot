# [FORK CONNECTEI] modifications/030-deploy-4.15.1.13.md
#
# Reinscreve os canais Instagram (Instagram Login) no webhook do app, com os
# campos atuais (`Connectei::Instagram::SubscribedFields`, mod 024). Usado pela
# rake `connectei:instagram:resubscribe` no deploy da 4.15.1.13: canal conectado
# antes dela assina só `messages message_reactions messaging_seen` e não recebe
# postback, referral nem comentário até ser reinscrito.
#
# Chama o próprio `Channel::Instagram#subscribe` — a mesma chamada da criação do
# canal e do PATCH da mod 003 —, então não há regra duplicada aqui. Um canal que
# falha não interrompe os outros; o resumo diz quantos falharam.
class Connectei::Instagram::Resubscriber
  Result = Struct.new(:channel_id, :inbox_id, :instagram_id, :fields, :status, :detail, keyword_init: true)

  def initialize(dry_run: false, channel_ids: [], io: $stdout)
    @dry_run = dry_run
    @channel_ids = Array(channel_ids).compact_blank
    @io = io
  end

  def perform
    results = []
    scope.find_each { |channel| results << report(resubscribe(channel)) }
    summarize(results)
    results
  end

  private

  def scope
    @channel_ids.present? ? Channel::Instagram.where(id: @channel_ids) : Channel::Instagram.all
  end

  def resubscribe(channel)
    fields = Connectei::Instagram::SubscribedFields.fields_for(channel)
    base = { channel_id: channel.id, inbox_id: channel.inbox&.id, instagram_id: channel.instagram_id, fields: fields }
    return Result.new(**base, status: :dry_run) if @dry_run

    status, detail = interpret(channel.subscribe)
    Result.new(**base, status: status, detail: detail)
  end

  # `subscribe` devolve a resposta da Graph, ou `true` quando uma exceção foi
  # engolida (o motivo fica no log em nível debug, como no upstream).
  def interpret(response)
    return [:error, 'exceção na chamada à Graph (ver log em debug)'] unless response.respond_to?(:code)

    parsed = response.parsed_response
    return [:ok, nil] if response.success? && !(parsed.is_a?(Hash) && parsed['success'] == false)

    [:failed, "HTTP #{response.code}: #{response.body.to_s.truncate(300)}"]
  end

  def report(result)
    line = "channel_id=#{result.channel_id} inbox_id=#{result.inbox_id} instagram_id=#{result.instagram_id} " \
           "fields=#{result.fields.join(',')} status=#{result.status}"
    line += " detail=#{result.detail}" if result.detail.present?
    @io.puts(line)
    result
  end

  def summarize(results)
    counts = results.group_by(&:status).transform_values(&:size)
    @io.puts("[connectei:instagram:resubscribe] #{results.size} canal(is): " \
             "#{counts.map { |status, total| "#{total} #{status}" }.join(', ').presence || 'nenhum'}")
  end
end
