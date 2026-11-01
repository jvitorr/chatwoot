require 'rails_helper'

# [FORK CONNECTEI] modifications/024
describe Connectei::Instagram::SubscribedFields do
  let(:base_fields) { %w[messages message_reactions messaging_seen messaging_postbacks messaging_referral] }

  describe '.fields_for' do
    it 'subscribes messages, reactions, seen, postbacks and referral when no scope was granted' do
      channel = build(:channel_instagram, connectei_granted_scopes: [])

      expect(described_class.fields_for(channel)).to eq(base_fields)
    end

    it 'adds comments only when instagram_business_manage_comments was granted' do
      channel = build(:channel_instagram, connectei_granted_scopes: %w[instagram_business_basic instagram_business_manage_comments])

      expect(described_class.fields_for(channel)).to eq(base_fields + ['comments'])
    end

    it 'does not add comments for the messages scope alone' do
      channel = build(:channel_instagram, connectei_granted_scopes: %w[instagram_business_manage_messages])

      expect(described_class.fields_for(channel)).not_to include('comments')
    end
  end

  describe '.normalize_scopes' do
    it 'accepts a list and a comma/space separated string (the OAuth "permissions" format)' do
      expect(described_class.normalize_scopes(%w[a_b c_d])).to eq(%w[a_b c_d])
      expect(described_class.normalize_scopes('instagram_business_basic, instagram_business_manage_comments'))
        .to eq(%w[instagram_business_basic instagram_business_manage_comments])
    end

    it 'strips, deduplicates and drops values that are not scope names' do
      expect(described_class.normalize_scopes([' a_b ', 'a_b', '', nil, 'x;drop table', 'z' * 101])).to eq(['a_b'])
    end

    it 'returns an empty list for blank input' do
      expect(described_class.normalize_scopes(nil)).to eq([])
      expect(described_class.normalize_scopes([])).to eq([])
    end
  end
end
