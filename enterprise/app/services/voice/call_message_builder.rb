class Voice::CallMessageBuilder
  # Maps Call model statuses to voice_call display statuses (hyphenated for frontend)
  CALL_TO_VOICE_STATUS = {
    'ringing' => 'ringing',
    'in_progress' => 'in-progress',
    'failed' => 'failed',
    'no_answer' => 'no-answer',
    'completed' => 'completed'
  }.freeze

  def self.create!(conversation:, call:, user: nil)
    new(conversation: conversation, call: call, user: user).create!
  end

  # Backwards-compatible entry used by Voice::OutboundCallBuilder (Twilio).
  def self.perform!(call:)
    create!(conversation: call.conversation, call: call, user: call.accepted_by_agent)
  end

  def self.update_status!(call:, status: nil, agent: nil, duration_seconds: nil)
    new(conversation: call.conversation, call: call).update_status!(
      status: status, agent: agent, duration_seconds: duration_seconds
    )
  end

  def initialize(conversation:, call:, user: nil)
    @conversation = conversation
    @call = call
    @user = user
  end

  def create!
    # Direct create rather than Messages::MessageBuilder because the latter
    # rejects `incoming` messages on non-Api inboxes — that gate is meant for
    # human messages flowing through chatbot-style integrations, but a voice
    # call bubble is a system event that needs to live on the WhatsApp inbox.
    Message.create!(
      conversation: conversation,
      account: conversation.account,
      inbox: conversation.inbox,
      content: message_content,
      message_type: message_type,
      content_type: 'voice_call',
      content_attributes: { 'data' => build_data_payload },
      sender: sender
    )
  end

  def update_status!(status:, agent: nil, duration_seconds: nil)
    message = call.message
    return unless message

    data = (message.content_attributes || {}).dup
    data['data'] ||= {}
    data['data']['status'] = map_status(status) if status
    data['data']['accepted_by'] = { 'id' => agent.id, 'name' => agent.name } if agent
    data['data']['duration_seconds'] = duration_seconds if duration_seconds

    message.update!(content_attributes: data)
    message
  end

  private

  attr_reader :conversation, :call, :user

  # `call_source` lets the FE disambiguate WhatsApp vs Twilio for UI copy
  # and event routing without loading the whole Call record client-side.
  # `media_server_enabled` is hard-coded to false because WhatsApp now runs
  # browser↔Meta WebRTC directly (no media server) and Twilio's bubble
  # never gates on this flag. Rejoin is unsupported across the board.
  def build_data_payload
    {
      'call_sid' => call.provider_call_id,
      'status' => map_status(call.status),
      'call_direction' => call.direction_label,
      'call_source' => call.provider,
      'call_id' => call.id,
      'from_number' => from_number,
      'to_number' => to_number,
      'media_server_enabled' => false,
      'meta' => { 'created_at' => Time.zone.now.to_i }
    }
  end

  def message_content
    call.twilio? ? 'Voice Call' : 'WhatsApp Call'
  end

  def message_type
    call.outgoing? ? 'outgoing' : 'incoming'
  end

  def sender
    return user if call.outgoing? && user

    conversation.contact
  end

  def from_number
    if call.incoming?
      conversation.contact&.phone_number
    else
      conversation.inbox.channel&.phone_number
    end
  end

  def to_number
    if call.incoming?
      conversation.inbox.channel&.phone_number
    else
      conversation.contact&.phone_number
    end
  end

  def map_status(status)
    CALL_TO_VOICE_STATUS[status] || status
  end
end
