require 'rails_helper'

# [FORK CONNECTEI] modifications/029 — webhook de conta com retry para inbox Instagram.
RSpec.describe Connectei::InstagramAccountWebhookJob do
  include ActiveJob::TestHelper

  subject(:job) { described_class.perform_later(url, payload, :instagram_account_webhook, secret: 'segredo', delivery_id: 'delivery-1') }

  let(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let!(:message) { create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :incoming) }
  let(:url) { 'https://erp.test/v1/chatwoot-public/webhook' }
  let(:payload) { { event: 'message_created', id: message.id, conversation: { id: conversation.display_id } } }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(GlobalConfig).to receive(:get_value).and_call_original
    allow(GlobalConfig).to receive(:get_value).with('WEBHOOK_TIMEOUT').and_return(5)
  end

  after do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'queues on medium, like the mod 006 job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(url, payload, :instagram_account_webhook, secret: 'segredo', delivery_id: 'delivery-1').on_queue('medium')
  end

  it 'retries a 5xx up to 5 attempts and keeps the same delivery id and a fresh signature on each one' do
    attempts = []
    allow(SafeFetch).to receive(:fetch) do |_url, **options|
      attempts << options[:headers]
      raise SafeFetch::HttpError, '503 Service Unavailable'
    end

    perform_enqueued_jobs { job }

    expect(attempts.size).to eq(5)
    expect(attempts.map { |headers| headers['X-Chatwoot-Delivery'] }.uniq).to eq(['delivery-1'])
    expect(attempts).to all(include('X-Chatwoot-Signature', 'X-Chatwoot-Timestamp'))
  end

  it 'retries a transport error (ERP down) and succeeds when it comes back' do
    calls = 0
    allow(SafeFetch).to receive(:fetch) do
      calls += 1
      raise Errno::ECONNREFUSED if calls < 3
    end

    perform_enqueued_jobs { job }

    expect(calls).to eq(3)
  end

  it 'does not retry an explicit 4xx and never touches the Instagram message' do
    calls = 0
    allow(SafeFetch).to receive(:fetch) do
      calls += 1
      raise SafeFetch::HttpError, '422 Unprocessable Entity'
    end

    perform_enqueued_jobs { job }

    expect(calls).to eq(1)
    expect(message.reload.status).to eq('sent')
  end

  it 'does not mark the message failed when the retries are exhausted (it was already delivered to Instagram)' do
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError, '500 Internal Server Error')

    perform_enqueued_jobs { job }

    expect(message.reload.status).to eq('sent')
    expect(message.content_attributes).not_to have_key('external_error')
  end

  describe 'Webhooks::Trigger' do
    it 'raises RetryableError for the Instagram account webhook type, as for the API inbox' do
      allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError, '503 Service Unavailable')

      expect { Webhooks::Trigger.execute(url, payload, :instagram_account_webhook) }.to raise_error(Webhooks::Trigger::RetryableError)
    end

    it 'keeps the upstream account webhook without retry' do
      allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError, '503 Service Unavailable')

      expect { Webhooks::Trigger.execute(url, payload, :account_webhook) }.not_to raise_error
    end
  end
end
