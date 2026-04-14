class Voice::CallStatus::Manager
  pattr_initialize [:call!]

  ALLOWED_STATUSES = %w[ringing in-progress completed no-answer failed].freeze
  TERMINAL_STATUSES = %w[completed no-answer failed].freeze

  # Map dashed statuses (Twilio-native / frontend) to underscored Call model statuses.
  CALL_MODEL_STATUS = {
    'ringing' => 'ringing',
    'in-progress' => 'in_progress',
    'completed' => 'completed',
    'no-answer' => 'no_answer',
    'failed' => 'failed'
  }.freeze

  def process_status_update(status, duration: nil, timestamp: nil)
    return unless ALLOWED_STATUSES.include?(status)
    return if current_status == status

    apply_status(status, duration: duration, timestamp: timestamp)
    update_message(status)
  end

  private

  delegate :conversation, to: :call

  def current_status
    conversation.additional_attributes&.dig('call_status')
  end

  def apply_status(status, duration:, timestamp:)
    attrs = (conversation.additional_attributes || {}).dup
    attrs['call_status'] = status

    if status == 'in-progress'
      attrs['call_started_at'] ||= timestamp || now_seconds
    elsif TERMINAL_STATUSES.include?(status)
      attrs['call_ended_at'] = timestamp || now_seconds
      attrs['call_duration'] = resolved_duration(attrs, duration, timestamp)
    end

    conversation.update!(
      additional_attributes: attrs,
      last_activity_at: current_time
    )

    persist_on_call!(status, attrs)
  end

  def persist_on_call!(status, attrs)
    updates = { status: CALL_MODEL_STATUS[status] }
    updates[:started_at] = Time.zone.at(attrs['call_started_at']) if status == 'in-progress' && attrs['call_started_at']
    updates[:duration_seconds] = attrs['call_duration'] if TERMINAL_STATUSES.include?(status) && attrs['call_duration']

    call.update!(updates)
  end

  def resolved_duration(attrs, provided_duration, timestamp)
    return provided_duration if provided_duration

    started_at = attrs['call_started_at']
    return unless started_at && timestamp

    [timestamp - started_at.to_i, 0].max
  end

  def update_message(status)
    message = call.message || fallback_message
    return unless message

    data = (message.content_attributes || {}).dup
    data['data'] ||= {}
    data['data']['status'] = status

    message.update!(content_attributes: data)
  end

  def fallback_message
    conversation.messages.voice_calls
                .where("content_attributes -> 'data' ->> 'call_sid' = ?", call.provider_call_id)
                .order(created_at: :desc)
                .first
  end

  def now_seconds
    current_time.to_i
  end

  def current_time
    @current_time ||= Time.zone.now
  end
end
