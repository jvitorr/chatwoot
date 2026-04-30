class Voice::CallMessageBuilder
  def self.update_status!(call:, status: nil, agent: nil, duration_seconds: nil)
    new(call).update_status!(status: status, agent: agent, duration_seconds: duration_seconds)
  end

  def initialize(call)
    @call = call
  end

  def perform!
    call.message || create_message!
  end

  def update_status!(status:, agent: nil, duration_seconds: nil)
    message = call.message
    return unless message

    data = (message.content_attributes || {}).deep_dup
    data['data'] ||= {}
    data['data']['status'] = status.to_s.tr('_', '-') if status
    data['data']['accepted_by'] = { 'id' => agent.id, 'name' => agent.name } if agent
    data['data']['duration_seconds'] = duration_seconds if duration_seconds

    message.update!(content_attributes: data)
    message
  end

  private

  attr_reader :call

  def create_message!
    params = {
      content: 'Voice Call',
      message_type: call.outgoing? ? 'outgoing' : 'incoming',
      content_type: 'voice_call',
      content_attributes: { 'data' => build_data_payload }
    }
    Messages::MessageBuilder.new(sender, call.conversation, params).perform
  end

  def sender
    call.outgoing? ? call.accepted_by_agent : call.contact
  end

  # `call_source` lets the FE disambiguate WhatsApp vs Twilio for UI copy and
  # event routing without fetching the whole Call record client-side.
  def build_data_payload
    {
      'call_id' => call.id,
      'call_sid' => call.provider_call_id,
      'call_source' => call.provider,
      'call_direction' => call.direction_label,
      'status' => call.display_status
    }
  end
end
