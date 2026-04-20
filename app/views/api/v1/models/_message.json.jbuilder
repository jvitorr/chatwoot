json.id message.id
json.content message.content
json.inbox_id message.inbox_id
json.echo_id message.echo_id if message.echo_id
json.conversation_id message.conversation.display_id
json.message_type message.message_type_before_type_cast
json.content_type message.content_type
json.status message.status
json.content_attributes message.content_attributes
json.created_at message.created_at.to_i
json.private message.private
json.source_id message.source_id
json.sender message.sender.push_event_data if message.sender
json.attachments message.attachments.map(&:push_event_data) if message.attachments.present?

if message.content_type == 'voice_call' && message.respond_to?(:call) && message.call.present?
  call = message.call
  json.call do
    json.id call.id
    json.provider_call_id call.provider_call_id
    json.provider call.provider
    json.direction call.direction
    json.status call.display_status
    json.duration_seconds call.duration_seconds
    json.conference_sid call.conference_sid
    json.accepted_by_agent_id call.accepted_by_agent_id
    json.started_at call.started_at&.to_i
    json.ended_at call.ended_at
    json.from_number call.from_number
    json.to_number call.to_number
    json.recording_url call.recording_url
    json.transcript call.transcript
  end
end
