class Voice::Conference::Manager
  pattr_initialize [:call!, :event!, :participant_label]

  def process
    case event
    when 'start'
      ensure_conference_sid!
      mark_ringing!
    when 'join'
      mark_in_progress! if agent_participant?
    when 'leave'
      handle_leave!
    when 'end'
      finalize_conference!
    end
  end

  private

  delegate :conversation, to: :call

  def status_manager
    @status_manager ||= Voice::CallStatus::Manager.new(call: call)
  end

  def ensure_conference_sid!
    name = Voice::Conference::Name.for(call)
    call.update!(meta: call.meta.merge('conference_sid' => name)) if call.meta['conference_sid'].blank?

    conv_attrs = (conversation.additional_attributes || {}).dup
    return if conv_attrs['conference_sid'].present?

    conv_attrs['conference_sid'] = name
    conversation.update!(additional_attributes: conv_attrs)
  end

  def mark_ringing!
    return if current_status

    status_manager.process_status_update('ringing')
  end

  def mark_in_progress!
    status_manager.process_status_update('in-progress', timestamp: current_timestamp)
  end

  def handle_leave!
    case current_status
    when 'ringing'
      status_manager.process_status_update('no-answer', timestamp: current_timestamp)
    when 'in-progress'
      status_manager.process_status_update('completed', timestamp: current_timestamp)
    end
  end

  def finalize_conference!
    return if %w[completed no-answer failed].include?(current_status)

    status_manager.process_status_update('completed', timestamp: current_timestamp)
  end

  def current_status
    conversation.additional_attributes&.dig('call_status')
  end

  def agent_participant?
    participant_label.to_s.start_with?('agent')
  end

  def current_timestamp
    Time.zone.now.to_i
  end
end
