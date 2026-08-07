require 'rails_helper'

# [FORK CONNECTEI] modifications/009-retry-after-no-throttle.md
# rubocop:disable RSpec/SpecFilePathFormat -- testa o initializer, não a classe do gem
describe Rack::Attack do
  it 'exposes Retry-After on throttled (429) responses so integrators can reschedule precisely' do
    expect(described_class.throttled_response_retry_after_header).to be true
  end

  it 'keeps the contact search throttle keyed by account (tenant isolation)' do
    throttle = described_class.throttles.fetch('/api/v1/accounts/:account_id/contacts/search')

    request = Rack::Attack::Request.new(Rack::MockRequest.env_for('/api/v1/accounts/24/contacts/search?q=x'))
    expect(throttle.block.call(request)).to eq('24')
    expect(throttle.limit).to eq(ENV.fetch('RATE_LIMIT_CONTACT_SEARCH', '100').to_i)
    expect(throttle.period).to eq(1.minute)
  end
end
# rubocop:enable RSpec/SpecFilePathFormat
