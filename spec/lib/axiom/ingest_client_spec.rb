require 'rails_helper'

describe Axiom::IngestClient do
  let(:ingest_url) { 'https://api.axiom.co/v1/datasets/chatwoot/ingest' }

  it 'does nothing when the integration is disabled' do
    described_class.push([{ message: 'hello' }])

    expect(a_request(:post, ingest_url)).not_to have_been_made
  end

  context 'when enabled' do
    around do |example|
      with_modified_env(AXIOM_API_TOKEN: 'xaat-token') { example.run }
    end

    it 'posts a decorated array of events' do
      stub_request(:post, ingest_url).to_return(status: 200, body: '{}')

      described_class.push({ message: 'hello', level: 'error' })

      expect(a_request(:post, ingest_url).with do |request|
        payload = JSON.parse(request.body)
        event = payload.first
        payload.is_a?(Array) && event['message'] == 'hello' && event['level'] == 'error' &&
          event['service'] == 'chatwoot' && event['environment'] == 'test' && event['_time'].present? &&
          request.headers['Authorization'] == 'Bearer xaat-token' &&
          request.headers['Content-Type'] == 'application/json'
      end).to have_been_made
    end

    it 'skips empty payloads' do
      described_class.push([])

      expect(a_request(:post, ingest_url)).not_to have_been_made
    end

    it 'swallows network failures instead of raising' do
      stub_request(:post, ingest_url).to_timeout

      expect(Rails.logger).to receive(:warn).with(/Axiom ingest failed/)
      expect { described_class.push([{ message: 'hello' }]) }.not_to raise_error
    end
  end
end
