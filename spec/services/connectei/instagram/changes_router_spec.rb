require 'rails_helper'

# [FORK CONNECTEI] modifications/024
describe Connectei::Instagram::ChangesRouter do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram, account: account, instagram_id: '17841400000000000') }
  let(:inbox) { channel.inbox }
  let(:forward_env) do
    { CONNECTEI_INSTAGRAM_EVENTS_URL: 'https://erp.test/v1/chatwoot-public/instagram-events', CONNECTEI_INSTAGRAM_EVENTS_SECRET: 'segredo' }
  end
  let(:comment_value) do
    {
      id: '17890000000000001',
      text: 'QUERO',
      from: { id: '1234567890', username: 'cliente_x' },
      media: { id: '17900000000000009', media_product_type: 'REELS' },
      created_time: 1_730_375_990
    }
  end
  let(:expected_comment_payload) do
    {
      version: 1,
      event: 'instagram.comment',
      event_id: 'ig:c:17890000000000001',
      account_id: account.id,
      inbox_id: inbox.id,
      instagram_id: '17841400000000000',
      entry_time: 1_730_376_000_000,
      received_at: '2026-10-31T12:00:00Z',
      data: {
        comment_id: '17890000000000001',
        text: 'QUERO',
        from: { id: '1234567890', username: 'cliente_x' },
        media: { id: '17900000000000009', media_product_type: 'REELS' },
        parent_id: nil,
        created_time: 1_730_375_990
      }
    }
  end

  around do |example|
    travel_to(Time.utc(2026, 10, 31, 12, 0, 0)) { with_modified_env(forward_env) { example.run } }
  end

  def changes_entry(value, field: 'comments')
    { id: '17841400000000000', time: 1_730_376_000, changes: [{ field: field, value: value }] }
  end

  describe 'comments' do
    it 'normalizes a comment in the entry[].changes[] format and enqueues the forward' do
      expect(described_class.route(changes_entry(comment_value))).to be(true)

      expect(Connectei::ForwardInstagramEventJob).to have_been_enqueued.with(expected_comment_payload).exactly(:once)
    end

    it 'normalizes a comment in the entry[] {field, value} format to the same body' do
      entry = { id: '17841400000000000', time: 1_730_376_000, field: 'comments', value: comment_value }

      expect(described_class.route(entry)).to be(true)

      expect(Connectei::ForwardInstagramEventJob).to have_been_enqueued.with(expected_comment_payload).exactly(:once)
    end

    it 'reads comment_id from value.comment_id and keeps parent_id of replies' do
      value = comment_value.except(:id, :created_time).merge(comment_id: '17890000000000002', parent_id: '17890000000000001')

      described_class.route(changes_entry(value))

      expect(Connectei::ForwardInstagramEventJob).to have_been_enqueued.with(
        hash_including(event_id: 'ig:c:17890000000000002',
                       data: hash_including(comment_id: '17890000000000002', parent_id: '17890000000000001', created_time: nil))
      )
    end

    it 'ignores the account own comment (public reply loop) but still consumes the entry' do
      own = comment_value.merge(from: { id: '17841400000000000', username: 'minha_loja' })

      expect(described_class.route(changes_entry(own))).to be(true)

      expect(Connectei::ForwardInstagramEventJob).not_to have_been_enqueued
    end

    it 'does not forward a comment without comment_id' do
      expect(described_class.route(changes_entry(comment_value.except(:id)))).to be(true)

      expect(Connectei::ForwardInstagramEventJob).not_to have_been_enqueued
    end

    it 'does not forward live_comments (out of scope)' do
      expect(described_class.route(changes_entry(comment_value, field: 'live_comments'))).to be(true)

      expect(Connectei::ForwardInstagramEventJob).not_to have_been_enqueued
    end

    it 'does not forward when the instagram account has no channel here' do
      entry = changes_entry(comment_value).merge(id: '999')

      expect(described_class.route(entry)).to be(true)

      expect(Connectei::ForwardInstagramEventJob).not_to have_been_enqueued
    end

    it 'does not enqueue anything when forwarding is not configured' do
      with_modified_env(CONNECTEI_INSTAGRAM_EVENTS_URL: nil) do
        expect(described_class.route(changes_entry(comment_value))).to be(true)
      end

      expect(Connectei::ForwardInstagramEventJob).not_to have_been_enqueued
    end

    it 'never raises: a failure while forwarding is logged and the entry is still consumed' do
      allow(Connectei::Instagram::EventPayload).to receive(:comment).and_raise(StandardError, 'boom')
      allow(Rails.logger).to receive(:error)

      expect(described_class.route(changes_entry(comment_value))).to be(true)
      expect(Rails.logger).to have_received(:error).with(/falha ao repassar evento.*boom/)
    end
  end

  describe 'Meta test event' do
    it 'hands the dashboard test payload (field messages with sender/recipient) back to the job' do
      value = { sender: { id: '12334' }, recipient: { id: '23245' }, message: { mid: 'random_mid', text: 'random_text' } }

      expect(described_class.route(changes_entry(value, field: 'messages'))).to be(false)
      expect(Connectei::ForwardInstagramEventJob).not_to have_been_enqueued
    end

    it 'consumes a messages change without sender, instead of crashing the TestEventService' do
      expect(described_class.route(changes_entry({ foo: 'bar' }, field: 'messages'))).to be(true)
    end
  end

  describe 'standalone referral (messaging_referral)' do
    let(:referral_messaging) do
      {
        sender: { id: '1234567890' },
        recipient: { id: '17841400000000000' },
        timestamp: 1_730_376_000_000,
        referral: { ref: 'campanha=natal&vendedor=ana', source: 'SHORTLINKS', type: 'OPEN_THREAD' }
      }
    end

    it 'forwards it as instagram.referral and lets the job keep processing the entry' do
      entry = { id: '17841400000000000', time: 1_730_376_000_123, messaging: [referral_messaging] }

      expect(described_class.route(entry)).to be(false)

      expect(Connectei::ForwardInstagramEventJob).to have_been_enqueued.with(
        version: 1, event: 'instagram.referral', event_id: 'ig:r:1234567890:1730376000000',
        account_id: account.id, inbox_id: inbox.id, instagram_id: '17841400000000000',
        entry_time: 1_730_376_000_123, received_at: '2026-10-31T12:00:00Z',
        data: { sender_id: '1234567890', ref: 'campanha=natal&vendedor=ana', source: 'SHORTLINKS', type: 'OPEN_THREAD',
                ad_id: nil, ads_context_data: nil, timestamp: 1_730_376_000_000 }
      )
    end

    it 'does not forward a referral that came together with a message (it goes into content_attributes)' do
      messaging = referral_messaging.merge(message: { mid: 'm1', text: 'oi' })

      described_class.route({ id: '17841400000000000', messaging: [messaging] })

      expect(Connectei::ForwardInstagramEventJob).not_to have_been_enqueued
    end

    it 'does not mutate the entry owned by the job' do
      entry = { id: '17841400000000000', messaging: [referral_messaging], standby: [] }.with_indifferent_access

      described_class.route(entry)

      expect(entry[:messaging].size).to eq(1)
      expect(entry[:standby]).to eq([])
    end
  end

  describe '.without_messaging?' do
    it 'is true only when no entry carries messaging/standby' do
      expect(described_class.without_messaging?([changes_entry(comment_value)])).to be(true)
      expect(described_class.without_messaging?([changes_entry(comment_value), { messaging: [{}] }])).to be(false)
      expect(described_class.without_messaging?([])).to be(false)
    end
  end
end
