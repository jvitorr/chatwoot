require 'rails_helper'

describe Axiom::LogDevice do
  subject(:device) { described_class.new(buffer_limit: 3, flush_interval: 3600) }

  def buffer
    device.instance_variable_get(:@buffer)
  end

  describe '#write' do
    it 'never delivers on the calling thread' do
      # The whole point: request and job threads must not pay for an HTTP call.
      expect(Axiom::IngestClient).not_to receive(:push)

      10.times { |i| device.write({ message: i }) }
    end

    it 'buffers the events for the flush thread' do
      device.write({ message: 'one' })
      device.write({ message: 'two' })

      expect(buffer).to eq [{ message: 'one' }, { message: 'two' }]
    end

    it 'signals the flush thread once the buffer limit is reached' do
      condition = device.instance_variable_get(:@ready)
      expect(condition).to receive(:signal).once

      3.times { |i| device.write({ message: i }) }
    end

    it 'drops the oldest events instead of growing without bound' do
      capped = described_class.new(buffer_limit: 1000, flush_interval: 3600, max_buffer: 3)

      5.times { |i| capped.write({ message: i }) }

      expect(capped.instance_variable_get(:@buffer)).to eq [{ message: 2 }, { message: 3 }, { message: 4 }]
    end

    it 'ignores events emitted while delivering, so a failed push cannot feed itself' do
      Thread.current[:axiom_delivering] = true
      device.write({ message: 'from the delivery path' })

      expect(buffer).to be_empty
    ensure
      Thread.current[:axiom_delivering] = nil
    end
  end

  describe '#flush' do
    it 'ships the buffered events' do
      expect(Axiom::IngestClient).to receive(:push).with([{ message: 'one' }])

      device.write({ message: 'one' })
      device.flush
    end

    it 'empties the buffer so events are not sent twice' do
      allow(Axiom::IngestClient).to receive(:push)

      device.write({ message: 'one' })
      device.flush
      device.flush

      expect(Axiom::IngestClient).to have_received(:push).once
    end

    it 'does not call the API when there is nothing buffered' do
      expect(Axiom::IngestClient).not_to receive(:push)

      device.flush
    end

    it 'clears the re-entrancy guard even when the push raises' do
      allow(Axiom::IngestClient).to receive(:push).and_raise(StandardError)

      device.write({ message: 'one' })
      expect { device.flush }.to raise_error(StandardError)
      expect(Thread.current[:axiom_delivering]).to be_nil
    end
  end

  describe '#close' do
    it 'flushes what is pending' do
      expect(Axiom::IngestClient).to receive(:push).with([{ message: 'one' }])

      device.write({ message: 'one' })
      device.close
    end
  end
end
