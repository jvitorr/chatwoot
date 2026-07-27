require 'rails_helper'
# explicitly requiring since we are loading apms conditionally in application.rb
require 'sentry-ruby'

describe ChatwootExceptionTracker do
  it 'use rails logger if no tracker is configured' do
    expect(Rails.logger).to receive(:error).with('random')
    described_class.new('random').capture_exception
  end

  context 'with sentry DSN' do
    before do
      # since sentry is not initated in test, we need to do it manually
      Sentry.init do |config|
        config.dsn = 'test'
      end
    end

    it 'will call sentry capture exception' do
      with_modified_env SENTRY_DSN: 'random dsn' do
        expect(Sentry).to receive(:capture_exception).with('random')
        described_class.new('random').capture_exception
      end
    end

    it 'will also ship to axiom when both are configured' do
      with_modified_env SENTRY_DSN: 'random dsn', AXIOM_API_TOKEN: 'xaat-token' do
        expect(Sentry).to receive(:capture_exception).with('random')
        expect { described_class.new('random').capture_exception }.to have_enqueued_job(Axiom::IngestJob)
      end
    end
  end

  context 'without axiom token' do
    it 'does not enqueue an axiom ingest job' do
      expect { described_class.new('random').capture_exception }.not_to have_enqueued_job(Axiom::IngestJob)
    end
  end

  context 'with axiom token' do
    let(:account) { create(:account) }
    let(:user) { create(:user) }

    around do |example|
      with_modified_env(AXIOM_API_TOKEN: 'xaat-token') { example.run }
    end

    it 'enqueues an ingest job with the exception details' do
      exception = StandardError.new('boom')

      expect { described_class.new(exception).capture_exception }.to(
        have_enqueued_job(Axiom::IngestJob).with do |events|
          event = events.first
          expect(event[:level]).to eq 'error'
          expect(event[:message]).to eq 'boom'
          expect(event[:exception_class]).to eq 'StandardError'
        end
      )
    end

    it 'includes account and user context when available' do
      expect { described_class.new(StandardError.new('boom'), user: user, account: account).capture_exception }.to(
        have_enqueued_job(Axiom::IngestJob).with do |events|
          event = events.first
          expect(event[:account_id]).to eq account.id
          expect(event[:account_name]).to eq account.name
          expect(event[:user_id]).to eq user.id
          expect(event[:user_email]).to eq user.email
        end
      )
    end

    it 'does not raise when enqueuing fails' do
      allow(Axiom::IngestJob).to receive(:perform_later).and_raise(StandardError.new('redis down'))

      expect(Rails.logger).to receive(:warn).with(/Axiom exception capture failed/)
      expect(Rails.logger).to receive(:error)
      expect { described_class.new('random').capture_exception }.not_to raise_error
    end
  end
end
