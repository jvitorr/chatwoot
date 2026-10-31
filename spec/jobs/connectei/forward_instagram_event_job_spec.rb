require 'rails_helper'

# [FORK CONNECTEI] modifications/024
RSpec.describe Connectei::ForwardInstagramEventJob do
  let(:url) { 'https://erp.test/v1/chatwoot-public/instagram-events' }
  let(:payload) { { version: 1, event: 'instagram.comment', event_id: 'ig:c:1', data: { comment_id: '1' } } }

  around do |example|
    with_modified_env(CONNECTEI_INSTAGRAM_EVENTS_URL: url, CONNECTEI_INSTAGRAM_EVENTS_SECRET: 'segredo') { example.run }
  end

  it 'runs on its own Sidekiq queue, registered in config/sidekiq.yml below default' do
    queues = YAML.safe_load(ERB.new(Rails.root.join('config/sidekiq.yml').read).result, permitted_classes: [Symbol])[:queues]

    expect(described_class.new.queue_name).to eq('connectei_instagram')
    expect(queues).to include('connectei_instagram')
    expect(queues.index('connectei_instagram')).to be > queues.index('default')
  end

  it 'reschedules itself on a 5xx from the ERP' do
    stub_request(:post, url).to_return(status: 503)

    described_class.perform_now(payload)

    expect(described_class).to have_been_enqueued.with(payload).exactly(:once)
  end

  it 'gives up after 15 attempts and lets the error reach Sidekiq (dead set)' do
    stub_request(:post, url).to_return(status: 500)
    job = described_class.new(payload)
    # O retry_on conta tentativas por exceção (`exception_executions`), não pelo `executions` geral.
    job.exception_executions = { [Connectei::Instagram::EventForwarder::RetryableError].to_s => 14 }

    expect { job.perform_now }.to raise_error(Connectei::Instagram::EventForwarder::RetryableError)
  end

  [401, 422].each do |status|
    it "does not reschedule on #{status}" do
      stub_request(:post, url).to_return(status: status)

      described_class.perform_now(payload)

      expect(described_class).not_to have_been_enqueued
    end
  end

  it 'recomputes the signed timestamp on every attempt' do
    timestamps = []
    stub_request(:post, url).with { |request| timestamps << request.headers['X-Chatwoot-Timestamp'] }.to_return(status: 503)

    travel_to(Time.utc(2026, 10, 31, 12, 0, 0)) { described_class.perform_now(payload) }
    travel_to(Time.utc(2026, 11, 1, 12, 0, 0)) { described_class.perform_now(payload) }

    expect(timestamps).to eq([Time.utc(2026, 10, 31, 12).to_i.to_s, Time.utc(2026, 11, 1, 12).to_i.to_s])
  end
end
