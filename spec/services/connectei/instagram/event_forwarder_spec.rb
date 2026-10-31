require 'rails_helper'

# [FORK CONNECTEI] modifications/024
describe Connectei::Instagram::EventForwarder do
  let(:url) { 'https://erp.test/v1/chatwoot-public/instagram-events' }
  let(:secret) { 'segredo-de-teste' }
  let(:payload) { { version: 1, event: 'instagram.comment', event_id: 'ig:c:1', data: { comment_id: '1', text: 'QUERO' } } }
  let(:body) { payload.to_json }

  around do |example|
    with_modified_env(CONNECTEI_INSTAGRAM_EVENTS_URL: url, CONNECTEI_INSTAGRAM_EVENTS_SECRET: secret) { example.run }
  end

  describe 'signature (contract §1.1)' do
    it 'signs "<timestamp>.<raw body>" with HMAC-SHA256 and sends the timestamp header' do
      freeze_time do
        timestamp = Time.now.to_i.to_s
        expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{body}")}"
        request = stub_request(:post, url)
                  .with(body: body, headers: { 'Content-Type' => 'application/json', 'X-Chatwoot-Timestamp' => timestamp,
                                               'X-Chatwoot-Signature' => expected })
                  .to_return(status: 202)

        expect(described_class.new(payload).perform).to eq(:delivered)
        expect(request).to have_been_requested.once
      end
    end

    it 'does not use the mod 001 header (the ERP has no receiver for it)' do
      stub_request(:post, url).to_return(status: 202)

      described_class.new(payload).perform

      expect(a_request(:post, url).with { |req| req.headers.key?('X-Connectei-Signature') }).not_to have_been_made
    end
  end

  describe 'responses (contract §1.3)' do
    it 'treats 202 (accepted, duplicates included) as delivered' do
      stub_request(:post, url).to_return(status: 202)

      expect(described_class.new(payload).perform).to eq(:delivered)
    end

    [500, 502, 503, 504, 408, 429].each do |status|
      it "raises RetryableError on #{status}" do
        stub_request(:post, url).to_return(status: status)

        expect { described_class.new(payload).perform }.to raise_error(described_class::RetryableError, /#{status}/)
      end
    end

    it 'raises RetryableError on timeout and network errors' do
      stub_request(:post, url).to_timeout
      expect { described_class.new(payload).perform }.to raise_error(described_class::RetryableError, /ERP unreachable/)

      stub_request(:post, url).to_raise(Errno::ECONNREFUSED)
      expect { described_class.new(payload).perform }.to raise_error(described_class::RetryableError, /ERP unreachable/)
    end

    [401, 422].each do |status|
      it "does not retry on #{status} and logs an error" do
        stub_request(:post, url).to_return(status: status, body: '{"error":"invalid"}')
        allow(Rails.logger).to receive(:error)

        expect(described_class.new(payload).perform).to eq(:rejected)
        expect(Rails.logger).to have_received(:error).with(/ERP recusou ig:c:1 \(#{status}\)/)
      end
    end

    it 'does not follow redirects (a 3xx is a broken contract, not a new target)' do
      stub_request(:post, url).to_return(status: 302, headers: { 'Location' => 'https://elsewhere.test/' })

      expect(described_class.new(payload).perform).to eq(:rejected)
      expect(a_request(:get, 'https://elsewhere.test/')).not_to have_been_made
    end
  end

  describe 'without configuration' do
    before { described_class.unconfigured_logged = nil }

    it 'does not post, and logs at info level only once per process' do
      allow(Rails.logger).to receive(:info)

      with_modified_env(CONNECTEI_INSTAGRAM_EVENTS_SECRET: nil) do
        expect(described_class.new(payload).perform).to eq(:disabled)
        expect(described_class.new(payload).perform).to eq(:disabled)
      end

      expect(a_request(:post, url)).not_to have_been_made
      expect(Rails.logger).to have_received(:info).with(/repasse desativado: CONNECTEI_INSTAGRAM_EVENTS_SECRET/).once
    end
  end
end
