class Voice::CallMessageBuilder
  def self.perform!(conversation:, direction:, payload:, user: nil, timestamps: {})
    new(
      conversation: conversation,
      direction: direction,
      payload: payload,
      user: user,
      timestamps: timestamps
    ).perform!
  end

  def initialize(conversation:, direction:, payload:, user:, timestamps:)
    @conversation = conversation
    @direction = direction
    @payload = payload
    @user = user
    @timestamps = timestamps
  end

  def perform!
    validate_sender!
    existing = existing_message
    existing ? update_message!(existing) : create_message!
  end

  private

  attr_reader :conversation, :direction, :payload, :user, :timestamps

  def existing_message
    sid = payload[:call_sid] || payload['call_sid']
    return if sid.blank?

    conversation.messages.voice_calls
                .where("content_attributes -> 'data' ->> 'call_sid' = ?", sid)
                .first
  end

  def update_message!(message)
    message.update!(
      message_type: message_type,
      content_attributes: { 'data' => base_payload },
      sender: sender
    )
    message
  end

  def create_message!
    params = {
      content: 'Voice Call',
      message_type: message_type,
      content_type: 'voice_call',
      content_attributes: { 'data' => base_payload }
    }
    Messages::MessageBuilder.new(sender, conversation, params).perform
  end

  def base_payload
    @base_payload ||= begin
      data = payload.slice(
        :call_sid,
        :status,
        :call_direction,
        :conference_sid,
        :from_number,
        :to_number
      ).stringify_keys
      data['call_direction'] = direction
      data['meta'] = {
        'created_at' => timestamps[:created_at] || current_timestamp,
        'ringing_at' => timestamps[:ringing_at] || current_timestamp
      }.compact
      data
    end
  end

  def message_type
    direction == 'outbound' ? 'outgoing' : 'incoming'
  end

  def sender
    return user if direction == 'outbound'

    conversation.contact
  end

  def validate_sender!
    return unless direction == 'outbound'

    raise ArgumentError, 'Agent sender required for outbound calls' unless user
  end

  def current_timestamp
    @current_timestamp ||= Time.zone.now.to_i
  end
end
