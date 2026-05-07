require 'rails_helper'

RSpec.describe Conversations::UnreadCounts::Counter do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:visible_inbox) { create(:inbox, account: account) }
  let(:hidden_inbox) { create(:inbox, account: account) }
  let(:label) { create(:label, account: account, title: 'billing', show_on_sidebar: true) }
  let(:hidden_label) { create(:label, account: account, title: 'internal', show_on_sidebar: false) }
  let(:visible_team) { create(:team, account: account, allow_auto_assign: false) }
  let(:store) { Conversations::UnreadCounts::Store }

  before do
    create(:inbox_member, user: agent, inbox: visible_inbox)
    create(:team_member, user: agent, team: visible_team)
  end

  after do
    store.clear_account!(account.id)
  end

  it 'builds the base cache on demand' do
    create_unread_conversation(account: account, inbox: visible_inbox, labels: [label.title], team: visible_team)

    described_class.new(account: account, user: agent).perform

    expect(store.base_ready?(account.id)).to be(true)
  end

  it 'counts unread conversations only across inboxes visible to a normal agent' do
    create_unread_conversation(account: account, inbox: visible_inbox, labels: [label.title], team: visible_team)
    create_unread_conversation(account: account, inbox: hidden_inbox, labels: [label.title], team: visible_team)

    result = described_class.new(account: account, user: agent).perform

    expect(result).to eq(
      inboxes: { visible_inbox.id.to_s => 1 },
      labels: { label.id.to_s => 1 },
      teams: { visible_team.id.to_s => 1 }
    )
  end

  it 'counts unread conversations across all account inboxes for admins' do
    create_unread_conversation(account: account, inbox: visible_inbox, labels: [label.title], team: visible_team)
    create_unread_conversation(account: account, inbox: hidden_inbox, labels: [label.title], team: visible_team)

    result = described_class.new(account: account, user: admin).perform

    expect(result).to eq(
      inboxes: { visible_inbox.id.to_s => 1, hidden_inbox.id.to_s => 1 },
      labels: { label.id.to_s => 2 },
      teams: { visible_team.id.to_s => 2 }
    )
  end

  it 'does not return zero counts or labels hidden from the sidebar' do
    create_unread_conversation(account: account, inbox: visible_inbox, labels: [hidden_label.title], team: visible_team)

    result = described_class.new(account: account, user: agent).perform

    expect(result).to eq(
      inboxes: { visible_inbox.id.to_s => 1 },
      labels: {},
      teams: { visible_team.id.to_s => 1 }
    )
  end
end
