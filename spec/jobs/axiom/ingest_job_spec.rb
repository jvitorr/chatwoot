require 'rails_helper'

RSpec.describe Axiom::IngestJob do
  subject(:job) { described_class.perform_later([{ message: 'hello' }]) }

  it 'enqueues the job on the low queue' do
    expect { job }.to have_enqueued_job(described_class).on_queue('low')
  end

  it 'delegates to the ingest client' do
    expect(Axiom::IngestClient).to receive(:push).with([{ message: 'hello' }])

    described_class.perform_now([{ message: 'hello' }])
  end
end
