require 'rails_helper'

# [FORK CONNECTEI] modifications/024 — comentário real no lote do webhook.
describe Webhooks::InstagramEventsJob do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram, account: account, instagram_id: '17841400000000000') }
  let(:inbox) { channel.inbox }
  let(:forward_env) do
    { CONNECTEI_INSTAGRAM_EVENTS_URL: 'https://erp.test/v1/chatwoot-public/instagram-events', CONNECTEI_INSTAGRAM_EVENTS_SECRET: 'segredo' }
  end
  let(:comment_entry) do
    {
      id: '17841400000000000', time: 1_730_376_000,
      changes: [{ field: 'comments', value: { id: '17890000000000001', text: 'QUERO', from: { id: '555', username: 'cliente_x' },
                                              media: { id: '179', media_product_type: 'REELS' } } }]
    }
  end
  let(:dm_entry) do
    {
      id: '17841400000000000', time: 1_730_376_000_500,
      messaging: [{ sender: { id: '777' }, recipient: { id: '17841400000000000' }, timestamp: 1_730_376_000_500,
                    message: { mid: 'mid-dm-depois-do-comentario', text: 'oi, quero saber o preço' } }]
    }
  end

  before do
    stub_request(:get, %r{graph\.instagram\.com/v22\.0/777\?})
      .to_return(status: 200, body: { id: '777', name: 'Bia', username: 'bia' }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  around { |example| with_modified_env(forward_env) { example.run } }

  it 'processes the DM that comes after a real comment in the same batch (the batch no longer crashes)' do
    expect { described_class.perform_now([comment_entry, dm_entry]) }.not_to raise_error

    expect(inbox.messages.pluck(:source_id)).to eq(['mid-dm-depois-do-comentario'])
    expect(Connectei::ForwardInstagramEventJob).to have_been_enqueued.with(hash_including(event_id: 'ig:c:17890000000000001')).once
  end

  it 'never hands a real comment to the TestEventService' do
    allow(Instagram::TestEventService).to receive(:new).and_call_original

    described_class.perform_now([comment_entry])

    expect(Instagram::TestEventService).not_to have_received(:new)
  end

  it 'still processes the Meta dashboard test event through the TestEventService' do
    test_entry = {
      id: '0', time: 1_730_376_000,
      changes: [{ field: 'messages', value: { sender: { id: '12334' }, recipient: { id: '23245' }, timestamp: '1527459824',
                                              message: { mid: 'random_mid', text: 'random_text' } } }]
    }

    described_class.perform_now([test_entry])

    expect(Message.find_by(source_id: 'random_mid')&.content).to eq('random_text')
    expect(Connectei::ForwardInstagramEventJob).not_to have_been_enqueued
  end

  it 'does not take the per-contact mutex for a batch made only of comments' do
    lock_key = format(Redis::Alfred::IG_MESSAGE_MUTEX, sender_id: nil, ig_account_id: '17841400000000000')
    Redis::LockManager.new.lock(lock_key, 30.seconds)

    expect { described_class.perform_now([comment_entry]) }.not_to raise_error

    expect(Connectei::ForwardInstagramEventJob).to have_been_enqueued.once
  ensure
    Redis::LockManager.new.unlock(lock_key)
  end

  it 'forwards a standalone referral and keeps processing the messages of the same entry' do
    referral = { sender: { id: '777' }, recipient: { id: '17841400000000000' }, timestamp: 1_730_376_000_100,
                 referral: { ref: 'vendedor=ana', source: 'SHORTLINKS', type: 'OPEN_THREAD' } }
    entry = dm_entry.merge(messaging: [referral] + dm_entry[:messaging])

    described_class.perform_now([entry])

    expect(Connectei::ForwardInstagramEventJob).to have_been_enqueued.with(hash_including(event_id: 'ig:r:777:1730376000100')).once
    expect(inbox.messages.pluck(:source_id)).to eq(['mid-dm-depois-do-comentario'])
  end
end
