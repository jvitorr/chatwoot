require 'rails_helper'

# Connectei — ver modifications/012.
RSpec.describe 'Connectei Conversations API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: account) }

  def filter(params, user: admin)
    post "/api/v1/accounts/#{account.id}/connectei-conversations/filter",
         params: params, headers: user.create_new_auth_token, as: :json
  end

  def display_ids
    response.parsed_body['payload'].map { |item| item['id'] }
  end

  describe 'POST /connectei-conversations/filter' do
    it 'requires authentication' do
      post "/api/v1/accounts/#{account.id}/connectei-conversations/filter", as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'filters by status and reports a count consistent with the filter' do
      create(:conversation, account: account, inbox: inbox, status: :open)
      create(:conversation, account: account, inbox: inbox, status: :resolved)

      filter({ status: 'resolved' })

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].length).to eq(1)
      expect(response.parsed_body['meta']['all_count']).to eq(1)
    end

    it 'filters by multiple inboxes' do
      create(:conversation, account: account, inbox: inbox, status: :open)
      create(:conversation, account: account, inbox: other_inbox, status: :open)

      filter({ inbox_ids: [other_inbox.id] })

      expect(response.parsed_body['payload'].length).to eq(1)
      expect(response.parsed_body['payload'].first['inbox_id']).to eq(other_inbox.id)
    end

    it 'rejects an inbox from another account' do
      foreign_inbox = create(:inbox, account: create(:account))

      filter({ inbox_ids: [foreign_inbox.id] })

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'treats multiple labels as AND' do
      both = create(:conversation, account: account, inbox: inbox, status: :open)
      only_one = create(:conversation, account: account, inbox: inbox, status: :open)
      both.update_labels(%w[vip retorno])
      only_one.update_labels(%w[vip])

      filter({ labels: %w[vip retorno] })

      expect(display_ids).to eq([both.display_id])
    end

    it 'excludes conversations carrying an excluded label (group hiding)' do
      visible = create(:conversation, account: account, inbox: inbox, status: :open)
      group = create(:conversation, account: account, inbox: inbox, status: :open)
      group.update_labels(%w[erp-group])

      filter({ exclude_labels: ['erp-group'] })

      expect(display_ids).to eq([visible.display_id])
      expect(response.parsed_body['meta']['all_count']).to eq(1)
    end

    it 'filters the unassigned queue (painel "Pendentes")' do
      create(:conversation, account: account, inbox: inbox, status: :open, assignee: agent)
      unassigned = create(:conversation, account: account, inbox: inbox, status: :open, assignee: nil)

      filter({ status: 'open', unassigned: true })

      expect(display_ids).to eq([unassigned.display_id])
    end

    it 'filters by multiple assignees' do
      other_agent = create(:user, account: account, role: :agent)
      mine = create(:conversation, account: account, inbox: inbox, status: :open, assignee: agent)
      theirs = create(:conversation, account: account, inbox: inbox, status: :open, assignee: other_agent)
      create(:conversation, account: account, inbox: inbox, status: :open, assignee: nil)

      filter({ assignee_ids: [agent.id, other_agent.id] })

      expect(display_ids).to contain_exactly(mine.display_id, theirs.display_id)
    end

    it 'searches by contact name — impossible on the upstream filter API' do
      contact = create(:contact, account: account, name: 'Amanda Nunes')
      target = create(:conversation, account: account, inbox: inbox, contact: contact, status: :open)
      create(:conversation, account: account, inbox: inbox, status: :open)

      filter({ q: 'amanda' })

      expect(display_ids).to eq([target.display_id])
    end

    it 'searches by contact phone number' do
      contact = create(:contact, account: account, phone_number: '+5579910405067')
      target = create(:conversation, account: account, inbox: inbox, contact: contact, status: :open)

      filter({ q: '9104050' })

      expect(display_ids).to eq([target.display_id])
    end

    it 'searches by message content without duplicating the conversation' do
      target = create(:conversation, account: account, inbox: inbox, status: :open)
      create(:message, account: account, inbox: inbox, conversation: target, content: 'orçamento da lente', message_type: :incoming)
      create(:message, account: account, inbox: inbox, conversation: target, content: 'lente pronta', message_type: :outgoing)
      create(:conversation, account: account, inbox: inbox, status: :open)

      filter({ q: 'lente' })

      expect(display_ids).to eq([target.display_id])
    end

    it 'sorts by last activity in both directions' do
      older = create(:conversation, account: account, inbox: inbox, status: :open, last_activity_at: 2.days.ago)
      newer = create(:conversation, account: account, inbox: inbox, status: :open, last_activity_at: 1.hour.ago)

      filter({ sort_by: 'last_activity_at_asc' })
      expect(display_ids).to eq([older.display_id, newer.display_id])

      filter({ sort_by: 'last_activity_at_desc' })
      expect(display_ids).to eq([newer.display_id, older.display_id])
    end

    it 'keeps pinned conversations on top of the sort, across pagination' do
      newest = create(:conversation, account: account, inbox: inbox, status: :open, last_activity_at: 1.minute.ago)
      pinned = create(:conversation, account: account, inbox: inbox, status: :open, last_activity_at: 10.days.ago)

      filter({ pinned_display_ids: [pinned.display_id] })

      expect(display_ids).to eq([pinned.display_id, newest.display_id])
    end

    it 'paginates with a client-defined page size' do
      create_list(:conversation, 3, account: account, inbox: inbox, status: :open)

      filter({ per_page: 2, page: 2 })

      body = response.parsed_body
      expect(body['payload'].length).to eq(1)
      expect(body['meta']).to include('all_count' => 3, 'page' => 2, 'per_page' => 2, 'total_pages' => 2)
    end

    it 'returns unread count and last message without an extra round trip' do
      conversation = create(:conversation, account: account, inbox: inbox, status: :open, agent_last_seen_at: 1.day.ago)
      create(:message, account: account, inbox: inbox, conversation: conversation, content: 'primeira', message_type: :incoming,
                       created_at: 2.hours.ago)
      create(:message, account: account, inbox: inbox, conversation: conversation, content: 'ultima', message_type: :incoming,
                       created_at: 1.hour.ago)

      filter({})

      item = response.parsed_body['payload'].first
      expect(item['unread_count']).to eq(2)
      expect(item['last_message']['content']).to eq('ultima')
      expect(item['contact']).to include('name')
    end

    it 'restricts a regular agent to their own conversations plus the unassigned queue' do
      other_agent = create(:user, account: account, role: :agent)
      mine = create(:conversation, account: account, inbox: inbox, status: :open, assignee: agent)
      unassigned = create(:conversation, account: account, inbox: inbox, status: :open, assignee: nil)
      create(:conversation, account: account, inbox: inbox, status: :open, assignee: other_agent)

      filter({}, user: agent)

      expect(display_ids).to contain_exactly(mine.display_id, unassigned.display_id)
      expect(response.parsed_body['meta']['scope']).to eq('self')
    end
  end
end
