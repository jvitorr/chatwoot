require 'rails_helper'

# [FORK CONNECTEI] modifications/025
describe Connectei::Instagram::RateLimiter do
  # O MockRedis dos specs não é zerado entre exemplos: cada exemplo usa uma conta própria.
  let(:instagram_id) { "ig-#{SecureRandom.hex(6)}" }
  let(:limiter) { described_class.new(instagram_id) }

  describe 'private replies per hour (CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR)' do
    it 'allows up to the limit inside the sliding hour and then refuses with retry_after' do
      with_modified_env(CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR: '3') do
        freeze_time do
          3.times { expect(limiter.acquire_private_reply).to be_allowed }

          refused = limiter.acquire_private_reply
          expect(refused).not_to be_allowed
          expect(refused.limit_name).to eq('private_reply')
          expect(refused.retry_after).to be_between(3599, 3600)
        end
      end
    end

    it 'is a sliding window, not a clock-hour window (no double burst at the boundary)' do
      with_modified_env(CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR: '2') do
        travel_to(Time.utc(2026, 10, 31, 10, 59, 0)) { 2.times { limiter.acquire_private_reply } }

        travel_to(Time.utc(2026, 10, 31, 11, 1, 0)) { expect(limiter.acquire_private_reply).not_to be_allowed }
        travel_to(Time.utc(2026, 10, 31, 11, 59, 1)) { expect(limiter.acquire_private_reply).to be_allowed }
      end
    end

    it 'never lets the count inside the window exceed the ceiling (refused attempts do not occupy slots)' do
      with_modified_env(CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR: '5') do
        freeze_time do
          results = Array.new(20) { limiter.acquire_private_reply.allowed? }

          expect(results.count(true)).to eq(5)
          key = "CONNECTEI_IG_RATE::private_reply::#{instagram_id}"
          expect(Redis::Alfred.with { |conn| conn.zcard(key) }).to eq(5)
        end
      end
    end
  end

  describe 'sends per second (CONNECTEI_IG_SEND_PER_SECOND)' do
    it 'refuses the call over the per-second limit and frees it in the next second' do
      with_modified_env(CONNECTEI_IG_SEND_PER_SECOND: '2') do
        travel_to(Time.utc(2026, 10, 31, 12, 0, 0)) do
          2.times { expect(limiter.acquire_send).to be_allowed }
          expect(limiter.acquire_send).not_to be_allowed
        end

        travel_to(Time.utc(2026, 10, 31, 12, 0, 2)) { expect(limiter.acquire_send).to be_allowed }
      end
    end

    it 'counts each Instagram account separately' do
      with_modified_env(CONNECTEI_IG_SEND_PER_SECOND: '1') do
        freeze_time do
          expect(limiter.acquire_send).to be_allowed
          expect(described_class.new("#{instagram_id}-outra").acquire_send).to be_allowed
          expect(limiter.acquire_send).not_to be_allowed
        end
      end
    end
  end

  describe 'configuration' do
    it 'uses 90/s and 720/h by default and ignores invalid values' do
      with_modified_env(CONNECTEI_IG_SEND_PER_SECOND: nil, CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR: 'abc') do
        expect(described_class.send_per_second).to eq(90)
        expect(described_class.private_reply_per_hour).to eq(720)
      end

      with_modified_env(CONNECTEI_IG_SEND_PER_SECOND: '0', CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR: '-5') do
        expect(described_class.send_per_second).to eq(90)
        expect(described_class.private_reply_per_hour).to eq(720)
      end
    end
  end

  it 'fails open when Redis is unavailable' do
    allow(Redis::Alfred).to receive(:with).and_raise(Redis::CannotConnectError)
    allow(Rails.logger).to receive(:error)

    expect(limiter.acquire_private_reply).to be_allowed
    expect(Rails.logger).to have_received(:error).with(/limitador indisponível/)
  end
end
