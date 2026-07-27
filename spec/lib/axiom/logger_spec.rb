require 'rails_helper'

describe Axiom::Logger do
  describe '.normalize' do
    it 'keeps strings as is' do
      expect(described_class.normalize('boom')).to eq 'boom'
    end

    it 'renders exceptions with their class' do
      expect(described_class.normalize(StandardError.new('boom'))).to eq 'boom (StandardError)'
    end

    it 'inspects anything else' do
      expect(described_class.normalize({ a: 1 })).to eq '{a: 1}'
    end
  end

  describe '.build' do
    it 'emits structured events at the configured level' do
      with_modified_env AXIOM_LOG_LEVEL: 'info' do
        logger = described_class.build
        device = logger.instance_variable_get(:@logdev).dev
        expect(device).to be_a(Axiom::LogDevice)
        expect(logger.level).to eq Logger::INFO

        expect(device).to receive(:write) do |event|
          expect(event[:level]).to eq 'warn'
          expect(event[:message]).to eq 'boom'
          expect(event[:_time]).to be_present
        end
        logger.warn('boom')
      end
    end

    it 'drops messages below the configured level' do
      logger = described_class.build
      device = logger.instance_variable_get(:@logdev).dev

      expect(device).not_to receive(:write)
      logger.info('ignored')
    end
  end
end
