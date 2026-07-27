require 'rails_helper'

describe Axiom::Reporter do
  let(:exception) { StandardError.new('boom') }

  it 'does nothing when the integration is disabled' do
    expect { described_class.report(exception) }.not_to have_enqueued_job(Axiom::IngestJob)
  end

  context 'when enabled' do
    around do |example|
      with_modified_env(AXIOM_API_TOKEN: 'xaat-token') { example.run }
    end

    it 'enqueues an ingest job with the built event' do
      expect { described_class.report(exception) }.to(
        have_enqueued_job(Axiom::IngestJob).with do |events|
          expect(events.first[:message]).to eq 'boom'
          expect(events.first[:exception_class]).to eq 'StandardError'
        end
      )
    end

    it 'never raises when reporting fails' do
      allow(Axiom::IngestJob).to receive(:perform_later).and_raise(StandardError.new('redis down'))

      expect(Rails.logger).to receive(:warn).with(/Axiom exception capture failed/)
      expect { described_class.report(exception) }.not_to raise_error
    end
  end
end
