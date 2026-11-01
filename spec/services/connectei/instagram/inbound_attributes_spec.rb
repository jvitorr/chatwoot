require 'rails_helper'

# [FORK CONNECTEI] modifications/025
describe Connectei::Instagram::InboundAttributes do
  def messaging(message: nil, postback: nil, referral: nil)
    { sender: { id: '1' }, recipient: { id: '2' }, message: message, postback: postback, referral: referral }.compact
  end

  describe '.extract' do
    it 'marks a story mention from the attachment type, without needing the Graph' do
      attributes = described_class.extract(messaging(message: { mid: 'm', attachments: [{ type: 'story_mention', payload: { url: 'u' } }] }))

      expect(attributes).to eq(ig_event: 'story_mention')
    end

    it 'marks a story reply' do
      attributes = described_class.extract(messaging(message: { mid: 'm', text: 'lindo!', reply_to: { story: { id: 's', url: 'u' } } }))

      expect(attributes).to eq(ig_event: 'story_reply')
    end

    %w[share ig_post ig_reel ig_story].each do |type|
      it "marks a #{type} attachment as share" do
        attributes = described_class.extract(messaging(message: { mid: 'm', attachments: [{ type: type, payload: { url: 'u' } }] }))

        expect(attributes[:ig_event]).to eq('share')
      end
    end

    it 'reads the quick reply payload' do
      attributes = described_class.extract(messaging(message: { mid: 'm', text: 'Vermelho', quick_reply: { payload: 'menu:n1:i2' } }))

      expect(attributes).to eq(quick_reply_payload: 'menu:n1:i2')
    end

    it 'reads postback payload/title and the postback referral' do
      postback = { mid: 'p', title: 'Quais os horários?', payload: 'ib:3f2a', referral: { ref: 'natal', source: 'SHORTLINKS', type: 'OPEN_THREAD' } }

      expect(described_class.extract(messaging(postback: postback))).to eq(
        postback_payload: 'ib:3f2a', postback_title: 'Quais os horários?',
        referral: { 'ref' => 'natal', 'source' => 'SHORTLINKS', 'type' => 'OPEN_THREAD', 'ad_id' => nil, 'ads_context_data' => nil }
      )
    end

    it 'reads message.referral (ig.me link or ad) with the five keys' do
      referral = { ref: nil, source: 'ADS', type: 'OPEN_THREAD', ad_id: 120_000_000_001, ads_context_data: { ad_title: 'Promo' } }

      attributes = described_class.extract(messaging(message: { mid: 'm', text: 'oi', referral: referral }))

      expect(attributes[:referral]).to eq('ref' => nil, 'source' => 'ADS', 'type' => 'OPEN_THREAD', 'ad_id' => '120000000001',
                                          'ads_context_data' => { 'ad_title' => 'Promo' })
    end

    it 'returns nothing for a plain text message' do
      expect(described_class.extract(messaging(message: { mid: 'm', text: 'oi' }))).to eq({})
    end
  end
end
