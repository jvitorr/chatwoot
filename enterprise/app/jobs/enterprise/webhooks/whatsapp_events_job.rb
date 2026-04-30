module Enterprise::Webhooks::WhatsappEventsJob
  def handle_message_events(channel, params)
    return handle_call_events(channel, params) if call_event?(params)
    return handle_call_permission_reply(channel, params) if call_permission_reply?(params)

    super
  end

  private

  # OSS contact_sender_id returns nil for `field: 'calls'` payloads, which makes
  # the parent job bypass the per-(inbox, sender) mutex. That lets a fast
  # `terminate` webhook be processed before the `connect` transaction commits,
  # silently dropping the terminate and stranding the call as `ringing`. Falling
  # through to `call:<id>` reuses the existing mutex to serialize connect and
  # terminate for the same call.
  def contact_sender_id(params)
    super.presence || call_event_sender_id(params)
  end

  def call_event_sender_id(params)
    call_id = params.dig(:entry, 0, :changes, 0, :value, :calls, 0, :id)
    call_id.present? ? "call:#{call_id}" : nil
  end

  def call_event?(params)
    params.dig(:entry, 0, :changes, 0, :field) == 'calls'
  end

  def call_permission_reply?(params)
    message = params.dig(:entry, 0, :changes, 0, :value, :messages, 0)
    message&.dig(:type) == 'interactive' && message&.dig(:interactive, :type) == 'call_permission_reply'
  end

  def handle_call_events(channel, params)
    Whatsapp::IncomingCallService.new(
      inbox: channel.inbox,
      params: extract_call_params(params)
    ).perform
  end

  def handle_call_permission_reply(channel, params)
    Whatsapp::CallPermissionReplyService.new(inbox: channel.inbox, params: params).perform
  end

  def extract_call_params(params)
    params.dig(:entry, 0, :changes, 0, :value) || {}
  end
end
