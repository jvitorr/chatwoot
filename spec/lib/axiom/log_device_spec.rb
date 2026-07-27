require 'rails_helper'

describe Axiom::LogDevice do
  subject(:device) { described_class.new(buffer_limit: 3, flush_interval: 3600) }

  it 'buffers events until the limit is reached' do
    expect(Axiom::IngestClient).not_to receive(:push)

    device.write({ message: 'one' })
    device.write({ message: 'two' })
  end

  it 'ships the batch once the buffer limit is reached' do
    expect(Axiom::IngestClient).to receive(:push).with([{ message: 'one' }, { message: 'two' }, { message: 'three' }])

    device.write({ message: 'one' })
    device.write({ message: 'two' })
    device.write({ message: 'three' })
  end

  it 'empties the buffer after shipping' do
    allow(Axiom::IngestClient).to receive(:push)

    3.times { |i| device.write({ message: i }) }
    device.flush

    expect(Axiom::IngestClient).to have_received(:push).once
  end

  it 'ships pending events on flush' do
    expect(Axiom::IngestClient).to receive(:push).with([{ message: 'one' }])

    device.write({ message: 'one' })
    device.flush
  end

  it 'does not call the API when flushing an empty buffer' do
    expect(Axiom::IngestClient).not_to receive(:push)

    device.flush
  end

  it 'flushes on close' do
    expect(Axiom::IngestClient).to receive(:push).with([{ message: 'one' }])

    device.write({ message: 'one' })
    device.close
  end
end
