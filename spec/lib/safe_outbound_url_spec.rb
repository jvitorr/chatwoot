require 'rails_helper'

RSpec.describe SafeOutboundUrl do
  describe '.validate!' do
    let(:public_resolver) { ->(_hostname) { [IPAddr.new('93.184.216.34')] } }
    let(:private_resolver) { ->(_hostname) { [IPAddr.new('127.0.0.1')] } }

    it 'accepts public http urls' do
      uri = described_class.validate!('https://example.com/webhook', resolver: public_resolver)

      expect(uri).to be_a(URI::HTTPS)
      expect(uri.host).to eq('example.com')
    end

    it 'rejects non-http schemes' do
      expect do
        described_class.validate!('javascript:alert(1)', resolver: public_resolver)
      end.to raise_error(described_class::InvalidUrlError, 'scheme must be http or https')
    end

    it 'rejects hosts that resolve only to private addresses' do
      expect do
        described_class.validate!('http://internal.example.test/webhook', resolver: private_resolver)
      end.to raise_error(described_class::UnsafeUrlError, "Hostname 'internal.example.test' has no public ip addresses")
    end
  end
end
