require 'rails_helper'

# Connectei — ver modifications/011.
RSpec.describe 'Dashboard Attendants API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: account) }

  describe 'GET /api/v1/accounts/{account.id}/dashboard-attendants' do
    context 'when unauthenticated' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/dashboard-attendants"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated as administrator' do
      before do
        create(:conversation, account: account, inbox: inbox, assignee: agent, status: :open)
        create(:conversation, account: account, inbox: inbox, assignee: agent, status: :resolved)
        create(:conversation, account: account, inbox: inbox, assignee: other_agent, status: :open)
        create(:conversation, account: account, inbox: inbox, assignee: nil, status: :open)
      end

      it 'groups counts by attendant in a single payload' do
        get "/api/v1/accounts/#{account.id}/dashboard-attendants",
            headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        body = response.parsed_body

        agent_entry = body['agents'].find { |item| item['id'] == agent.id }
        expect(agent_entry['counts']).to include('open' => 1, 'resolved' => 1)
        expect(agent_entry['conversations'].length).to eq(1)

        other_entry = body['agents'].find { |item| item['id'] == other_agent.id }
        expect(other_entry['counts']['open']).to eq(1)
      end

      it 'reports the unassigned queue separately' do
        get "/api/v1/accounts/#{account.id}/dashboard-attendants",
            headers: admin.create_new_auth_token, as: :json

        expect(response.parsed_body['unassigned']['counts']['open']).to eq(1)
        expect(response.parsed_body['unassigned']['conversations'].length).to eq(1)
      end

      it 'totals every status across attendants' do
        get "/api/v1/accounts/#{account.id}/dashboard-attendants",
            headers: admin.create_new_auth_token, as: :json

        expect(response.parsed_body['totals']).to include('open' => 3, 'resolved' => 1)
      end

      it 'scopes to the requested inboxes (multi-store isolation)' do
        create(:conversation, account: account, inbox: other_inbox, assignee: agent, status: :open)

        get "/api/v1/accounts/#{account.id}/dashboard-attendants",
            params: { inbox_ids: [other_inbox.id] },
            headers: admin.create_new_auth_token, as: :json

        body = response.parsed_body
        expect(body['meta']['inbox_ids']).to eq([other_inbox.id])
        expect(body['totals']['open']).to eq(1)
      end

      it 'rejects an inbox from another account instead of returning empty' do
        foreign_inbox = create(:inbox, account: create(:account))

        get "/api/v1/accounts/#{account.id}/dashboard-attendants",
            params: { inbox_ids: [foreign_inbox.id] },
            headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to include('not found in this account')
      end

      it 'caps the conversation slice per attendant in the database' do
        create_list(:conversation, 3, account: account, inbox: inbox, assignee: other_agent, status: :open)

        get "/api/v1/accounts/#{account.id}/dashboard-attendants",
            params: { conversations_per_agent: 2 },
            headers: admin.create_new_auth_token, as: :json

        entry = response.parsed_body['agents'].find { |item| item['id'] == other_agent.id }
        expect(entry['counts']['open']).to eq(4)
        expect(entry['conversations'].length).to eq(2)
      end
    end

    context 'when authenticated as a regular agent' do
      before do
        create(:conversation, account: account, inbox: inbox, assignee: agent, status: :open)
        create(:conversation, account: account, inbox: inbox, assignee: other_agent, status: :open)
        create(:conversation, account: account, inbox: inbox, assignee: nil, status: :open)
      end

      it 'sees only their own board plus the unassigned queue' do
        get "/api/v1/accounts/#{account.id}/dashboard-attendants",
            headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        body = response.parsed_body

        expect(body['meta']['scope']).to eq('self')
        expect(body['agents'].map { |item| item['id'] }).to eq([agent.id])
        expect(body['unassigned']['counts']['open']).to eq(1)
      end
    end
  end
end
