require 'rails_helper'

# [FORK CONNECTEI] modifications/025 — atributos de entrada do Instagram Login.
describe Messages::Instagram::MessageBuilder do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram, account: account, instagram_id: 'ig-business-1') }
  let(:inbox) { channel.inbox }
  let(:story_url) { 'https://lookaside.fbsbx.com/ig_messaging_cdn/?asset_id=1&signature=x' }

  before do
    contact = create(:contact, account: account)
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'igsid-1')
    stub_request(:get, story_url).to_return(status: 200, body: 'jpeg', headers: { 'Content-Type' => 'image/jpeg' })
  end

  def build_message(message)
    messaging = { sender: { id: 'igsid-1' }, recipient: { id: 'ig-business-1' }, timestamp: 1_730_376_000_000, message: message }
    described_class.new(messaging.with_indifferent_access, inbox).perform
    inbox.messages.last
  end

  def story_mention(mid = 'mid-mention')
    { mid: mid, attachments: [{ type: 'story_mention', payload: { url: story_url } }] }
  end

  describe 'ig_event = story_mention' do
    let(:story_lookup) { %r{graph\.instagram\.com/v22\.0/mid-mention\?.*fields=story,from} }

    it 'is recorded together with image_type when the Graph lookup succeeds' do
      stub_request(:get, story_lookup)
        .to_return(status: 200, body: { story: { mention: { id: 'story-9' } }, from: { username: 'cliente_x' } }.to_json)

      message = build_message(story_mention)

      expect(message.content_attributes).to include('ig_event' => 'story_mention', 'image_type' => 'story_mention', 'story_id' => 'story-9')
    end

    it 'is recorded even when the Graph lookup answers with an error (image_type is lost, the marker is not)' do
      stub_request(:get, story_lookup).to_return(status: 500, body: { error: { code: 1, message: 'unknown' } }.to_json)

      message = build_message(story_mention)

      expect(message.content_attributes['ig_event']).to eq('story_mention')
      expect(message.content_attributes).not_to have_key('image_type')
      expect(message.attachments.count).to eq(1)
    end

    it 'keeps the message (and the marker) when the Graph lookup times out' do
      stub_request(:get, story_lookup).to_raise(Net::ReadTimeout)

      message = build_message(story_mention)

      expect(message).to be_present
      expect(message.content_attributes['ig_event']).to eq('story_mention')
    end

    it 'keeps the message when the Graph answers an error page that is not JSON' do
      stub_request(:get, story_lookup).to_return(status: 502, body: '<html>Bad Gateway</html>')

      expect(build_message(story_mention).content_attributes['ig_event']).to eq('story_mention')
    end

    # O download da mídia também roda DENTRO da transação: um 404 da CDN da Meta
    # (story expirada) ou uma conexão recusada desfaziam a menção inteira — e o
    # ERP nunca via o evento que dispara a automação (achado no E2E local).
    context 'when the story media can no longer be downloaded' do
      before do
        stub_request(:get, story_lookup)
          .to_return(status: 200, body: { story: { mention: { id: 'story-9' } }, from: { username: 'cliente_x' } }.to_json)
      end

      it 'keeps the message, the marker and the story data when the CDN answers 404' do
        stub_request(:get, story_url).to_return(status: 404, body: 'gone')

        message = build_message(story_mention)

        expect(message).to be_present
        expect(message.content_attributes).to include('ig_event' => 'story_mention', 'image_type' => 'story_mention', 'story_id' => 'story-9')
        expect(message.attachments.count).to eq(1)
        expect(message.attachments.first.external_url).to eq(story_url)
        expect(message.attachments.first.file).not_to be_attached
      end

      it 'keeps the message when the media host refuses the connection' do
        stub_request(:get, story_url).to_raise(Errno::ECONNREFUSED)

        message = build_message(story_mention)

        expect(message).to be_present
        expect(message.content_attributes['ig_event']).to eq('story_mention')
      end
    end
  end

  it 'keeps a shared post whose media can no longer be downloaded (marker included)' do
    stub_request(:get, story_url).to_return(status: 404, body: 'gone')

    message = build_message({ mid: 'mid-share-gone', attachments: [{ type: 'share', payload: { url: story_url } }] })

    expect(message).to be_present
    expect(message.content_attributes['ig_event']).to eq('share')
  end

  it 'marks a story reply as ig_event = story_reply' do
    message = build_message({ mid: 'mid-reply', text: 'que lindo!', reply_to: { story: { id: 'story-1', url: story_url } } })

    expect(message.content_attributes).to include('ig_event' => 'story_reply', 'image_type' => 'ig_story_reply')
  end

  it 'marks a shared post as ig_event = share' do
    message = build_message({ mid: 'mid-share', attachments: [{ type: 'ig_post', payload: { url: story_url } }] })

    expect(message.content_attributes['ig_event']).to eq('share')
  end

  it 'stores the quick reply payload of a tap' do
    message = build_message({ mid: 'mid-qr', text: 'Vermelho', quick_reply: { payload: 'menu:n1:i2' } })

    expect(message.content).to eq('Vermelho')
    expect(message.content_attributes['quick_reply_payload']).to eq('menu:n1:i2')
  end

  it 'stores message.referral (ig.me link / ad)' do
    message = build_message({ mid: 'mid-ref', text: 'oi', referral: { ref: 'vendedor=ana', source: 'SHORTLINKS', type: 'OPEN_THREAD' } })

    expect(message.content_attributes['referral']).to eq(
      'ref' => 'vendedor=ana', 'source' => 'SHORTLINKS', 'type' => 'OPEN_THREAD', 'ad_id' => nil, 'ads_context_data' => nil
    )
  end

  it 'stores postback payload, title and postback.referral when the job turns a postback into a message' do
    stub_request(:get, %r{graph\.instagram\.com/v22\.0/igsid-1\?}).to_return(status: 200, body: { id: 'igsid-1', username: 'x' }.to_json)
    entries = [{
      id: 'ig-business-1', time: 1_730_376_000_000,
      messaging: [{ sender: { id: 'igsid-1' }, recipient: { id: 'ig-business-1' }, timestamp: 1_730_376_000_000,
                    postback: { mid: 'mid-pb', title: 'Quais os horários?', payload: 'ib:3f2a',
                                referral: { ref: 'natal', source: 'SHORTLINKS', type: 'OPEN_THREAD' } } }]
    }]

    Webhooks::InstagramEventsJob.perform_now(entries)

    message = inbox.messages.find_by!(source_id: 'mid-pb')
    expect(message.content).to eq('Quais os horários?')
    expect(message.content_attributes).to include('postback_payload' => 'ib:3f2a', 'postback_title' => 'Quais os horários?')
    expect(message.content_attributes.dig('referral', 'ref')).to eq('natal')
  end
end
