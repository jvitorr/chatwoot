require 'rails_helper'

RSpec.describe WebhookJob do
  include ActiveJob::TestHelper

  subject(:job) { described_class.perform_later(url, payload, webhook_type) }

  let(:url) { 'https://test.chatwoot.com' }
  let(:payload) { { name: 'test' } }
  let(:webhook_type) { :account_webhook }

  it 'queues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(url, payload, webhook_type)
      .on_queue('medium')
  end

  it 'executes perform with default webhook type' do
    expect(Webhooks::Trigger).to receive(:execute).with(url, payload, webhook_type, secret: nil, delivery_id: nil)
    perform_enqueued_jobs { job }
  end

  context 'with custom webhook type' do
    let(:webhook_type) { :api_inbox_webhook }

    it 'executes perform with inbox webhook type' do
      expect(Webhooks::Trigger).to receive(:execute).with(url, payload, webhook_type, secret: nil, delivery_id: nil)
      perform_enqueued_jobs { job }
    end
  end

  # [FORK CONNECTEI] modifications/023-webhook-de-conta-retry.md
  # Webhook de conta = canal de eventos do ERP. Sem retry, uma mensagem do
  # cliente enviada durante um deploy/restart do ERP se perdia para sempre.
  context 'when an account webhook delivery fails transiently' do
    subject(:job) do
      described_class.perform_later(url, payload, :account_webhook, secret: secret, delivery_id: delivery_id)
    end

    let(:url) { 'https://erp.example.com/v1/chatwoot/webhook/2' }
    let(:payload) { { event: 'message_created', id: 250_475, conversation: { id: 42 }, content: 'oi' } }
    let(:secret) { 'test-secret' }
    let(:delivery_id) { 'delivery-1' }
    let(:connection_refused) { Errno::ECONNREFUSED.new('Failed to open TCP connection to erp.example.com:443') }

    before do
      ActiveJob::Base.queue_adapter = :test
      allow(Rails.logger).to receive(:warn)
    end

    after do
      clear_enqueued_jobs
      clear_performed_jobs
    end

    it 'configures a retry handler for RetryableError' do
      expect(described_class.rescue_handlers.map(&:first)).to include('Webhooks::Trigger::RetryableError')
    end

    it 're-enqueues the same job with identical payload and delivery_id, scheduled in the future' do
      allow(SafeFetch).to receive(:fetch).and_raise(connection_refused)
      job

      perform_enqueued_jobs

      expect(SafeFetch).to have_received(:fetch).once
      expect(described_class).to have_been_enqueued
        .with(url, payload, :account_webhook, secret: secret, delivery_id: delivery_id).exactly(:once)
      expect(enqueued_jobs.last[:at]).to be > Time.current.to_f
    end

    it 'delivers once the ERP is back, with the same body and X-Chatwoot-Delivery on every attempt' do
      attempts = []
      allow(SafeFetch).to receive(:fetch) do |_url, **options|
        attempts << { body: options[:body], delivery: options[:headers]['X-Chatwoot-Delivery'] }
        raise connection_refused if attempts.size <= 2

        nil
      end

      perform_enqueued_jobs { job }

      expect(attempts.size).to eq(3)
      expect(attempts.pluck(:body).uniq).to eq([payload.to_json])
      expect(attempts.pluck(:delivery).uniq).to eq([delivery_id])
      expect(Rails.logger).to have_received(:warn)
        .with(/\[WebhookJob\] account_webhook attempt \d failed .*event=message_created id=250475 delivery_id=delivery-1/).twice
      expect(Rails.logger).not_to have_received(:warn).with(/Exception: Invalid webhook URL/)
    end

    it 'retries a 503 up to 5 attempts, then hands over to handle_failure without raising' do
      allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError.new('503 Service Unavailable'))

      expect { perform_enqueued_jobs { job } }.not_to raise_error

      expect(SafeFetch).to have_received(:fetch).exactly(5).times
      expect(Rails.logger).to have_received(:warn).with("Exception: Invalid webhook URL #{url} : 503 Service Unavailable").once
    end

    it 'does not retry an explicit 4xx' do
      allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError.new('404 Not Found'))

      perform_enqueued_jobs { job }

      expect(SafeFetch).to have_received(:fetch).once
      expect(Rails.logger).to have_received(:warn).with("Exception: Invalid webhook URL #{url} : 404 Not Found").once
      expect(Rails.logger).not_to have_received(:warn).with(/\[WebhookJob\] account_webhook attempt/)
    end

    it 'applies the same bounded retry to callers that omit the webhook type (automation/macro/installation)' do
      allow(SafeFetch).to receive(:fetch).and_raise(connection_refused)

      expect { perform_enqueued_jobs { described_class.perform_later(url, payload) } }.not_to raise_error

      expect(SafeFetch).to have_received(:fetch).exactly(5).times
      expect(Rails.logger).to have_received(:warn).with(/Exception: Invalid webhook URL #{url}/).once
    end
  end

  # [FORK CONNECTEI] modifications/023: o retry do WebhookJob é guardado pelo
  # tipo no Trigger — tipos sem política própria no WebhookJob base não mudam.
  context 'when an agent bot webhook fails with a transport error through the base job' do
    before { ActiveJob::Base.queue_adapter = :test }

    after do
      clear_enqueued_jobs
      clear_performed_jobs
    end

    it 'does not retry' do
      allow(SafeFetch).to receive(:fetch).and_raise(Errno::ECONNREFUSED)

      perform_enqueued_jobs { described_class.perform_later(url, payload, :agent_bot_webhook) }

      expect(SafeFetch).to have_received(:fetch).once
    end
  end
end
