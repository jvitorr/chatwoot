module Enterprise::Webhooks::WhatsappEventsJob
  def handle_message_events(channel, params)
    return handle_call_events(channel, params) if call_event?(params)
    return handle_call_permission_reply(channel, params) if call_permission_reply?(params)

    super
  end

  private

  # Lock per-call_id inside handle_call_events instead of the parent's per-sender mutex.
  def contact_sender_id(params)
    return nil if call_event?(params)

    super
  end

  def call_event?(params)
    params.dig(:entry, 0, :changes, 0, :field) == 'calls'
  end

  def call_permission_reply?(params)
    params.dig(:entry, 0, :changes, 0, :value, :messages, 0, :interactive, :type) == 'call_permission_reply'
  end

  # Per-call_id mutex so connect/terminate for the same call serialize across batches.
  def handle_call_events(channel, params)
    calls = params.dig(:entry, 0, :changes, 0, :value, :calls) || []
    calls.each do |call_payload|
      lock_key = format(::Redis::Alfred::WHATSAPP_MESSAGE_MUTEX,
                        inbox_id: channel.inbox.id, sender_id: "call:#{call_payload[:id]}")
      with_lock(lock_key, 30.seconds) do
        Whatsapp::IncomingCallService.new(inbox: channel.inbox, params: { calls: [call_payload] }).perform
      end
    end
  end

  def handle_call_permission_reply(channel, params)
    Whatsapp::CallPermissionReplyService.new(inbox: channel.inbox, params: params).perform
  end
end
