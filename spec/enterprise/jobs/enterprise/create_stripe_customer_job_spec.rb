require 'rails_helper'

RSpec.describe Enterprise::CreateStripeCustomerJob, type: :job do
  include ActiveJob::TestHelper
  subject(:job) { described_class.perform_later(account, billing_attribution) }

  let(:account) { create(:account) }
  let(:billing_attribution) { { 'visitor_id' => 'visitor-123', 'session_id' => 'session-123' } }

  it 'queues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(account, billing_attribution)
      .on_queue('default')
  end

  it 'executes perform' do
    create_stripe_customer_service = double
    allow(Enterprise::Billing::CreateStripeCustomerService)
      .to receive(:new)
      .with(account: account, billing_attribution: billing_attribution)
      .and_return(create_stripe_customer_service)
    allow(create_stripe_customer_service).to receive(:perform)

    perform_enqueued_jobs { job }

    expect(Enterprise::Billing::CreateStripeCustomerService)
      .to have_received(:new)
      .with(account: account, billing_attribution: billing_attribution)
  end
end
