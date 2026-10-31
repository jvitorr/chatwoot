require 'rails_helper'

# [FORK CONNECTEI] modifications/028
RSpec.describe Connectei::InstagramTokenRefreshJob do
  let(:account) { create(:account) }

  def channel_expiring_in(duration, token: SecureRandom.hex(16))
    channel = create(:channel_instagram, account: account, access_token: token)
    channel.update_columns(expires_at: duration.from_now, updated_at: 2.days.ago) # rubocop:disable Rails/SkipsModelValidations
    channel.reload
  end

  it 'is scheduled daily in config/schedule.yml' do
    schedule = YAML.load_file(Rails.root.join('config/schedule.yml'))

    expect(schedule['connectei_instagram_token_refresh_job']).to include(
      'class' => 'Connectei::InstagramTokenRefreshJob', 'cron' => '20 3 * * *', 'queue' => 'scheduled_jobs'
    )
  end

  describe 'without a channel id (cron entrypoint)' do
    it 'enqueues one job per channel that expires within 10 days and is still valid' do
      due = channel_expiring_in(5.days)
      not_due = channel_expiring_in(30.days)
      expired = channel_expiring_in(-1.day)

      described_class.perform_now

      expect(described_class).to have_been_enqueued.with(due.id).exactly(:once)
      expect(described_class).not_to have_been_enqueued.with(not_due.id)
      expect(described_class).not_to have_been_enqueued.with(expired.id)
    end

    it 'does not call the Graph itself' do
      channel_expiring_in(5.days)

      described_class.perform_now

      expect(a_request(:get, /refresh_access_token/)).not_to have_been_made
    end
  end

  describe 'with a channel id' do
    it 'renews the token through Instagram::RefreshOauthTokenService and pushes expires_at forward' do
      channel = channel_expiring_in(5.days, token: 'old-token')
      refresh = stub_request(:get, 'https://graph.instagram.com/refresh_access_token')
                .with(query: { grant_type: 'ig_refresh_token', access_token: 'old-token' })
                .to_return(status: 200, body: { access_token: 'new-token', expires_in: 5_184_000 }.to_json)

      described_class.perform_now(channel.id)

      channel.reload
      expect(refresh).to have_been_requested.once
      expect(channel.access_token).to eq('new-token')
      expect(channel.expires_at).to be > 50.days.from_now
    end

    it 'keeps the current token and logs a warning when the Meta refuses the refresh' do
      channel = channel_expiring_in(5.days, token: 'old-token')
      stub_request(:get, %r{graph\.instagram\.com/refresh_access_token}).to_return(status: 400, body: { error: { code: 190 } }.to_json)
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now(channel.id)

      expect(channel.reload[:access_token]).to eq('old-token')
      expect(Rails.logger).to have_received(:warn).with(/channel_id=#{channel.id} não renovado/)
    end

    it 'is a no-op for a channel that no longer exists' do
      expect { described_class.perform_now(-1) }.not_to raise_error
      expect(a_request(:get, /refresh_access_token/)).not_to have_been_made
    end
  end
end
