require 'rails_helper'

# [FORK CONNECTEI] modifications/029 — evento de inbox Instagram vai pelo job com retry.
describe WebhookListener do
  let(:listener) { described_class.instance }
  let(:account) { create(:account) }
  let!(:webhook) { create(:webhook, account: account) }
  let!(:channel) { create(:channel_instagram, account: account) }
  let(:instagram_inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: instagram_inbox) }
  let(:message) { create(:message, account: account, inbox: instagram_inbox, conversation: conversation, message_type: :incoming) }

  it 'delivers message_created of an Instagram inbox through Connectei::InstagramAccountWebhookJob' do
    allow(WebhookJob).to receive(:perform_later)
    expect(Connectei::InstagramAccountWebhookJob).to receive(:perform_later).with(
      webhook.url, message.webhook_data.merge(event: 'message_created'), :instagram_account_webhook,
      secret: webhook.secret, delivery_id: instance_of(String)
    ).once

    listener.message_created(Events::Base.new(:'message.created', Time.zone.now, message: message))

    expect(WebhookJob).not_to have_received(:perform_later)
  end

  it 'delivers message_updated and conversation_created of an Instagram inbox with retry too' do
    expect(Connectei::InstagramAccountWebhookJob).to receive(:perform_later).twice

    listener.message_updated(Events::Base.new(:'message.updated', Time.zone.now, message: message))
    listener.conversation_created(Events::Base.new(:'conversation.created', Time.zone.now, conversation: conversation))
  end

  it 'keeps WebhookJob (no retry) for other inboxes' do
    other_conversation = create(:conversation, account: account, inbox: create(:inbox, account: account))
    other_message = create(:message, account: account, inbox: other_conversation.inbox, conversation: other_conversation)
    expect(WebhookJob).to receive(:perform_later).with(anything, anything, :account_webhook, secret: webhook.secret,
                                                                                             delivery_id: instance_of(String)).once
    expect(Connectei::InstagramAccountWebhookJob).not_to receive(:perform_later)

    listener.message_created(Events::Base.new(:'message.created', Time.zone.now, message: other_message))
  end

  it 'keeps WebhookJob for account events without inbox (contact_created)' do
    contact = create(:contact, account: account)
    expect(WebhookJob).to receive(:perform_later).once
    expect(Connectei::InstagramAccountWebhookJob).not_to receive(:perform_later)

    listener.contact_created(Events::Base.new(:'contact.created', Time.zone.now, contact: contact))
  end
end
