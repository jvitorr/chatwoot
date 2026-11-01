require 'rake'
require 'rails_helper'

# [FORK CONNECTEI] modifications/030 — rake connectei:instagram:resubscribe.
RSpec.describe Rake::Task do
  subject(:task) { described_class['connectei:instagram:resubscribe'] }

  let(:account) { create(:account) }
  let(:base_fields) { %w[messages message_reactions messaging_seen messaging_postbacks messaging_referral] }
  let!(:plain) { create(:channel_instagram, account: account) }
  let!(:with_comments) { create(:channel_instagram, account: account, connectei_granted_scopes: %w[instagram_business_manage_comments]) }

  before { task.reenable }

  def subscribe_stub(channel, fields, status: 200, body: { success: true })
    stub_request(:post, "https://graph.instagram.com/v22.0/#{channel.instagram_id}/subscribed_apps")
      .with(query: { access_token: channel[:access_token], subscribed_fields: fields })
      .to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  it 'resubscribes every channel with the current fields (comments only where the scope was granted)' do
    WebMock.reset_executed_requests!
    plain_request = subscribe_stub(plain, base_fields)
    comments_request = subscribe_stub(with_comments, base_fields + ['comments'])

    expect { task.invoke }.to output(/2 canal\(is\): 2 ok/).to_stdout

    expect(plain_request).to have_been_requested.once
    expect(comments_request).to have_been_requested.once
  end

  it 'only lists what it would do with DRY_RUN=1' do
    WebMock.reset_executed_requests!

    with_modified_env(DRY_RUN: '1') do
      expect { task.invoke }.to output(/fields=#{base_fields.join(',')},comments status=dry_run/).to_stdout
    end

    expect(a_request(:post, /subscribed_apps/)).not_to have_been_made
  end

  it 'filters by CHANNEL_IDS' do
    WebMock.reset_executed_requests!
    subscribe_stub(plain, base_fields)

    with_modified_env(CHANNEL_IDS: plain.id.to_s) { expect { task.invoke }.to output(/1 canal\(is\): 1 ok/).to_stdout }

    expect(a_request(:post, /#{with_comments.instagram_id}/)).not_to have_been_made
  end

  it 'reports a Meta refusal and keeps going with the other channels' do
    subscribe_stub(plain, base_fields, status: 400, body: { error: { code: 190, message: 'Invalid OAuth access token' } })
    subscribe_stub(with_comments, base_fields + ['comments'])

    expect { task.invoke }.to output(/status=failed detail=HTTP 400.*2 canal\(is\): 1 failed, 1 ok/m).to_stdout
  end
end
