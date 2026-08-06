require 'rails_helper'

# [FORK CONNECTEI] modifications/006-webhook-inbox-api-timeout-retry.md
RSpec.describe ApiInbox::WebhookJob do
  include ActiveJob::TestHelper

  subject(:job) { described_class.perform_later(url, payload, webhook_type, secret: secret, delivery_id: delivery_id) }

  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:conversation) { create(:conversation, inbox: inbox) }
  let!(:message) { create(:message, account: account, inbox: inbox, conversation: conversation) }

  let(:url) { 'https://test.com' }
  let(:payload) { { event: 'message_created', conversation: { id: conversation.id }, id: message.id } }
  let(:webhook_type) { :api_inbox_webhook }
  let(:secret) { 'test-secret' }
  let(:delivery_id) { 'delivery-1' }

  before do
    ActiveJob::Base.queue_adapter = :test
  end

  after do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'queues the job on medium' do
    expect { job }.to have_enqueued_job(described_class)
      .with(url, payload, webhook_type, secret: secret, delivery_id: delivery_id)
      .on_queue('medium')
  end

  it 'delegates to Webhooks::Trigger' do
    expect(Webhooks::Trigger).to receive(:execute).with(url, payload, webhook_type, secret: secret, delivery_id: delivery_id)
    perform_enqueued_jobs { job }
  end

  it 'retries up to 5 attempts when the trigger raises RetryableError' do
    allow(Webhooks::Trigger).to receive(:execute)
      .and_raise(Webhooks::Trigger::RetryableError.new(status: nil, message: 'Net::ReadTimeout with #<TCPSocket:(closed)>'))

    perform_enqueued_jobs { job }

    expect(Webhooks::Trigger).to have_received(:execute).exactly(5).times
  end

  it 'records delivery_unconfirmed after retries are exhausted on an ambiguous transport error' do
    call_count = 0
    allow(SafeFetch).to receive(:fetch) do
      call_count += 1
      begin
        raise Net::ReadTimeout
      rescue Net::ReadTimeout => e
        raise SafeFetch::FetchError, e.message
      end
    end

    perform_enqueued_jobs { job }

    expect(call_count).to eq(5)
    message.reload
    expect(message.status).to eq('sent')
    expect(message.content_attributes['delivery_unconfirmed']).to be true
  end

  it 'marks the message failed after retries are exhausted on persistent http 500' do
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError.new('500 Internal Server Error'))

    perform_enqueued_jobs { job }

    expect(message.reload.status).to eq('failed')
  end
end
