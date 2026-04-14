class Voice::OutboundCallBuilder
  attr_reader :account, :inbox, :user, :contact

  def self.perform!(account:, inbox:, user:, contact:)
    new(account: account, inbox: inbox, user: user, contact: contact).perform!
  end

  def initialize(account:, inbox:, user:, contact:)
    @account = account
    @inbox = inbox
    @user = user
    @contact = contact
  end

  def perform!
    raise ArgumentError, 'Contact phone number required' if contact.phone_number.blank?
    raise ArgumentError, 'Agent required' if user.blank?

    timestamp = current_timestamp

    ActiveRecord::Base.transaction do
      contact_inbox = ensure_contact_inbox!
      conversation = create_conversation!(contact_inbox)
      conversation.reload

      call_sid = initiate_call!
      call = create_call!(conversation, call_sid, timestamp)
      message = build_voice_message!(conversation, call, timestamp)
      call.update!(message_id: message.id)

      denormalize_to_conversation!(conversation, call, timestamp)
      { conversation: conversation, call_sid: call_sid }
    end
  end

  private

  def ensure_contact_inbox!
    ContactInbox.find_or_create_by!(
      contact_id: contact.id,
      inbox_id: inbox.id
    ) do |record|
      record.source_id = contact.phone_number
    end
  end

  def create_conversation!(contact_inbox)
    account.conversations.create!(
      contact_inbox_id: contact_inbox.id,
      inbox_id: inbox.id,
      contact_id: contact.id,
      status: :open
    )
  end

  def initiate_call!
    inbox.channel.initiate_call(
      to: contact.phone_number
    )[:call_sid]
  end

  def create_call!(conversation, call_sid, timestamp)
    call = account.calls.create!(
      inbox: inbox,
      conversation: conversation,
      contact: contact,
      provider: :twilio,
      direction: :outgoing,
      status: 'ringing',
      provider_call_id: call_sid,
      accepted_by_agent_id: user.id,
      meta: { 'initiated_at' => timestamp }
    )
    call.update!(meta: call.meta.merge('conference_sid' => Voice::Conference::Name.for(call)))
    call
  end

  def build_voice_message!(conversation, call, timestamp)
    Voice::CallMessageBuilder.perform!(
      conversation: conversation,
      direction: 'outbound',
      payload: {
        call_sid: call.provider_call_id,
        status: 'ringing',
        conference_sid: call.meta['conference_sid'],
        from_number: inbox.channel&.phone_number,
        to_number: contact.phone_number
      },
      user: user,
      timestamps: { created_at: timestamp, ringing_at: timestamp }
    )
  end

  def denormalize_to_conversation!(conversation, call, timestamp)
    attrs = (conversation.additional_attributes || {}).merge(
      'call_direction' => 'outbound',
      'call_status' => 'ringing',
      'agent_id' => user.id,
      'conference_sid' => call.meta['conference_sid'],
      'meta' => { 'initiated_at' => timestamp }
    )

    conversation.update!(
      additional_attributes: attrs,
      last_activity_at: current_time
    )
  end

  def current_timestamp
    @current_timestamp ||= current_time.to_i
  end

  def current_time
    @current_time ||= Time.zone.now
  end
end
