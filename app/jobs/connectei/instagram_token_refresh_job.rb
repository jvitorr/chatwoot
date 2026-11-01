# [FORK CONNECTEI] modifications/028-instagram-graph-base-e-renovacao-de-token.md
#
# Renovação diária do token de longa duração dos canais Instagram (Instagram Login).
#
# POR QUE ISSO EXISTE
# O token vale 60 dias e o upstream só o renova de forma preguiçosa: dentro de
# `Channel::Instagram#access_token`, quando alguma mensagem entra ou sai. Um canal
# sem tráfego por ~60 dias (loja sazonal, conta recém-conectada que só recebe
# comentário) expira em silêncio e cai em "reautorização" — e o ERP não guarda
# o token para renovar por conta própria (mod 003).
#
# COMO FUNCIONA
# Sem argumento (cron diário, `config/schedule.yml`): enfileira um job por canal
# que expira nos próximos `REFRESH_WINDOW` e ainda não expirou. Com o id do canal:
# reaproveita `Instagram::RefreshOauthTokenService`, que só renova quando a Meta
# aceita (token válido, com mais de 24h e a menos de 10 dias de expirar).
# Um job por canal isola falhas: um token revogado não impede a renovação dos outros.
class Connectei::InstagramTokenRefreshJob < ApplicationJob
  queue_as :scheduled_jobs

  REFRESH_WINDOW = 10.days

  def perform(channel_id = nil)
    return refresh_channel(channel_id) if channel_id.present?

    enqueue_due_channels
  end

  private

  def enqueue_due_channels
    count = 0
    due_channels.find_each do |channel|
      self.class.perform_later(channel.id)
      count += 1
    end
    Rails.logger.info("[CONNECTEI][ig-token-refresh] #{count} canal(is) Instagram enfileirado(s) para renovação")
  end

  def due_channels
    Channel::Instagram.where(expires_at: Time.current..REFRESH_WINDOW.from_now)
  end

  def refresh_channel(channel_id)
    channel = Channel::Instagram.find_by(id: channel_id)
    return if channel.blank?

    previous_expiry = channel.expires_at
    ::Instagram::RefreshOauthTokenService.new(channel: channel).access_token
    log_outcome(channel, previous_expiry, channel.reload.expires_at)
  end

  def log_outcome(channel, previous_expiry, current_expiry)
    if current_expiry.present? && previous_expiry.present? && current_expiry > previous_expiry
      Rails.logger.info(
        "[CONNECTEI][ig-token-refresh] channel_id=#{channel.id} renovado: expira em #{current_expiry.iso8601}"
      )
    else
      # O service não levanta em falha (só registra e devolve o token antigo);
      # aqui fica o rastro por canal para quem investiga um canal que expirou.
      Rails.logger.warn(
        "[CONNECTEI][ig-token-refresh] channel_id=#{channel.id} não renovado " \
        "(expira em #{previous_expiry&.iso8601}); ver o log de 'Token refresh failed' do mesmo canal"
      )
    end
  end
end
