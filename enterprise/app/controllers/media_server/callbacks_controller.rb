class MediaServer::CallbacksController < ApplicationController
  before_action :validate_media_server_token

  def agent_disconnected
    call = find_call_by_session
    return head :not_found unless call

    ActionCable.server.broadcast(
      "account_#{call.account_id}",
      {
        event: 'whatsapp_call.agent_disconnected',
        data: { id: call.id, call_id: call.provider_call_id, conversation_id: call.conversation_id }
      }
    )
    head :ok
  end

  def recording_ready
    call = find_call_by_session
    return head :not_found unless call

    Whatsapp::CallRecordingFetchJob.perform_later(call.id)
    head :ok
  end

  def session_terminated
    call = find_call_by_session
    return head :not_found unless call
    return head :ok if call.terminal?

    reason = params[:reason] || 'media_server'
    was_answered = call.in_progress? || call.accepted_by_agent_id.present?
    final_status = was_answered ? 'completed' : 'failed'

    call.update!(status: final_status, end_reason: reason)

    ActionCable.server.broadcast(
      "account_#{call.account_id}",
      {
        event: 'whatsapp_call.ended',
        data: { id: call.id, call_id: call.provider_call_id, status: final_status, conversation_id: call.conversation_id }
      }
    )

    call.inbox.channel.provider_service.terminate_call(call.provider_call_id)
  rescue StandardError => e
    Rails.logger.error "[MEDIA SERVER] Failed to terminate on provider: #{e.message}"
  ensure
    head :ok unless performed?
  end

  private

  def validate_media_server_token
    token = request.headers['Authorization']&.sub('Bearer ', '')
    expected = ENV.fetch('MEDIA_SERVER_AUTH_TOKEN', '')
    head :unauthorized unless expected.present? && token.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected)
  end

  def find_call_by_session
    Call.find_by(media_session_id: params[:session_id])
  end
end
