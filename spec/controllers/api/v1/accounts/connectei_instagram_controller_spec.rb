require 'rails_helper'

# [FORK CONNECTEI] modifications/026 — endpoints `connectei-instagram` (contrato fork↔ERP §2).
RSpec.describe 'Connectei Instagram API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let!(:channel) { create(:channel_instagram, account: account, instagram_id: '17841400000000000') }
  let(:inbox) { channel.inbox }
  let(:graph) { 'https://graph.instagram.com/v22.0' }
  let(:token_headers) { { api_access_token: admin.access_token.token } }

  # O MockRedis não é desfeito entre exemplos e a conta aqui tem id fixo: zera a
  # janela do limitador por segundo para um exemplo não herdar a do anterior.
  before { Redis::Alfred.delete('CONNECTEI_IG_RATE::send::17841400000000000') }

  def base_path(inbox_id = inbox.id, account_id = account.id)
    "/api/v1/accounts/#{account_id}/connectei-instagram/inboxes/#{inbox_id}"
  end

  def graph_json(status, body, headers = {})
    { status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' }.merge(headers) }
  end

  def error_body
    response.parsed_body['error']
  end

  describe 'authentication and tenant isolation' do
    it 'requires the api access token' do
      get "#{base_path}/media"

      expect(response).to have_http_status(:unauthorized)
    end

    it 'answers 404 not_found for an Instagram inbox of another account' do
      foreign = create(:channel_instagram, account: create(:account))

      get "#{base_path(foreign.inbox.id)}/media", headers: token_headers

      expect(response).to have_http_status(:not_found)
      expect(error_body).to include('kind' => 'not_found', 'code' => nil, 'subcode' => nil, 'retry_after' => nil)
      expect(a_request(:get, %r{me/media})).not_to have_been_made
    end

    it 'answers 404 for an inbox of the account that is not Instagram' do
      api_inbox = create(:inbox, account: account)

      post "#{base_path(api_inbox.id)}/comment-threads", params: { igsid: '123' }, headers: token_headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(Conversation.count).to eq(0)
    end

    it 'answers 404 to an agent that is not a member of the inbox, and 200 to a member' do
      agent = create(:user, account: account, role: :agent)
      stub_request(:get, %r{#{graph}/me/media}).to_return(graph_json(200, { data: [] }))

      get "#{base_path}/media", headers: { api_access_token: agent.access_token.token }
      expect(response).to have_http_status(:not_found)

      create(:inbox_member, inbox: inbox, user: agent)
      get "#{base_path}/media", headers: { api_access_token: agent.access_token.token }
      expect(response).to have_http_status(:ok)
    end

    it 'answers 403 reauthorization_required without calling the Graph when the channel needs reconnection' do
      channel.prompt_reauthorization!

      get "#{base_path}/media", headers: token_headers

      expect(response).to have_http_status(:forbidden)
      expect(error_body['kind']).to eq('reauthorization_required')
      expect(a_request(:get, %r{me/media})).not_to have_been_made
    end
  end

  describe 'POST comment-threads' do
    let(:params) { { igsid: '1234567890', username: 'cliente_x', comment_id: '17890000000000001' } }

    it 'creates the contact without profile, the contact_inbox and a pending conversation, and no message' do
      post "#{base_path}/comment-threads", params: params, headers: token_headers, as: :json

      expect(response).to have_http_status(:ok)
      contact_inbox = inbox.contact_inboxes.find_by!(source_id: '1234567890')
      conversation = inbox.conversations.find_by!(display_id: response.parsed_body['conversation_id'])
      expect(response.parsed_body).to eq(
        'conversation_id' => conversation.display_id, 'conversation_status' => 'pending', 'contact_id' => contact_inbox.contact_id,
        'contact_inbox_id' => contact_inbox.id, 'source_id' => '1234567890', 'created' => true
      )
      expect(contact_inbox.contact.name).to eq('cliente_x')
      expect(contact_inbox.contact.additional_attributes).to include(
        'connectei_profile_pending' => true, 'social_instagram_user_name' => 'cliente_x', 'social_profiles' => { 'instagram' => 'cliente_x' }
      )
      expect(conversation.contact_inbox_id).to eq(contact_inbox.id)
      expect(conversation.messages.count).to eq(0)
      expect(a_request(:get, /graph\.instagram\.com/)).not_to have_been_made
    end

    it 'is idempotent: a second call reuses the same contact and conversation' do
      2.times { post "#{base_path}/comment-threads", params: params, headers: token_headers, as: :json }

      expect(response.parsed_body['created']).to be(false)
      expect(inbox.contact_inboxes.where(source_id: '1234567890').count).to eq(1)
      expect(inbox.conversations.count).to eq(1)
    end

    it 'does not touch an existing contact nor the status of its existing conversation' do
      contact = create(:contact, account: account, name: 'Maria Silva', additional_attributes: { 'social_instagram_user_name' => 'maria' })
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '1234567890')
      open_conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open)

      post "#{base_path}/comment-threads", params: params, headers: token_headers, as: :json

      expect(response.parsed_body).to include('conversation_id' => open_conversation.display_id, 'conversation_status' => 'open', 'created' => false)
      expect(contact.reload.name).to eq('Maria Silva')
      expect(contact.additional_attributes).not_to have_key('connectei_profile_pending')
    end

    it 'with lock_to_single_conversation reuses even a resolved conversation (without reopening it)' do
      inbox.update!(lock_to_single_conversation: true)
      contact_inbox = create(:contact_inbox, inbox: inbox, source_id: '1234567890')
      resolved = create(:conversation, account: account, inbox: inbox, contact: contact_inbox.contact, contact_inbox: contact_inbox,
                                       status: :resolved)

      post "#{base_path}/comment-threads", params: params, headers: token_headers, as: :json

      expect(response.parsed_body).to include('conversation_id' => resolved.display_id, 'created' => false)
      expect(resolved.reload.status).to eq('resolved')
    end

    it 'without lock_to_single_conversation opens a new pending conversation when the last one is resolved' do
      inbox.update!(lock_to_single_conversation: false)
      contact_inbox = create(:contact_inbox, inbox: inbox, source_id: '1234567890')
      create(:conversation, account: account, inbox: inbox, contact: contact_inbox.contact, contact_inbox: contact_inbox, status: :resolved)

      post "#{base_path}/comment-threads", params: params, headers: token_headers, as: :json

      expect(response.parsed_body).to include('conversation_status' => 'pending', 'created' => true)
      expect(inbox.conversations.count).to eq(2)
    end

    it 'rejects an invalid igsid with 422 invalid' do
      post "#{base_path}/comment-threads", params: { igsid: '../me', username: 'x' }, headers: token_headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(error_body['kind']).to eq('invalid')
      expect(Contact.count).to eq(0)
    end

    it 'answers 503 unavailable when the DM mutex of the contact does not free up' do
      stub_const('Connectei::Instagram::ThreadLock::MUTEX_WAIT', 0.2.seconds)
      key = format(Redis::Alfred::IG_MESSAGE_MUTEX, sender_id: '1234567890', ig_account_id: '17841400000000000')
      Redis::Alfred.set(key, 'dm-em-processamento', nx: true, ex: 30)

      post "#{base_path}/comment-threads", params: params, headers: token_headers, as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(error_body).to include('kind' => 'unavailable', 'retry_after' => 1)
      expect(Redis::Alfred.get(key)).to eq('dm-em-processamento')
    ensure
      Redis::Alfred.delete(key)
    end
  end

  describe 'POST comments/:comment_id/replies' do
    it 'posts the public reply and returns its id' do
      reply = stub_request(:post, %r{#{graph}/17890000000000001/replies}).with(query: hash_including(message: 'Te mandei no direct! 😉'))
                                                                         .to_return(graph_json(200, { id: '17950000000000003' }))

      post "#{base_path}/comments/17890000000000001/replies", params: { message: 'Te mandei no direct! 😉' }, headers: token_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('id' => '17950000000000003')
      expect(reply).to have_been_requested.once
    end

    it 'rejects an empty message with 422 without calling the Graph' do
      post "#{base_path}/comments/17890000000000001/replies", params: { message: ' ' }, headers: token_headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(a_request(:post, /replies/)).not_to have_been_made
    end

    it 'maps a Meta rate limit (613) to 429 rate_limited with Retry-After' do
      usage = { '1' => [{ 'estimated_time_to_regain_access' => 2 }] }.to_json
      meta_error = { error: { code: 613, message: 'Calls exceeded' } }
      stub_request(:post, /replies/).to_return(graph_json(400, meta_error, 'x-business-use-case-usage' => usage))

      post "#{base_path}/comments/1/replies", params: { message: 'oi' }, headers: token_headers, as: :json

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers['Retry-After']).to eq('120')
      expect(error_body).to include('kind' => 'rate_limited', 'code' => 613, 'retry_after' => 120)
    end

    it 'maps a timeout after sending to 504 ambiguous' do
      stub_request(:post, /replies/).to_raise(Net::ReadTimeout)

      post "#{base_path}/comments/1/replies", params: { message: 'oi' }, headers: token_headers, as: :json

      expect(response).to have_http_status(:gateway_timeout)
      expect(error_body['kind']).to eq('ambiguous')
    end

    it 'answers rate_limited from the fork limiter without calling the Graph' do
      with_modified_env(CONNECTEI_IG_SEND_PER_SECOND: '1') do
        freeze_time do
          stub_request(:post, /replies/).to_return(graph_json(200, { id: '1' }))
          2.times { post "#{base_path}/comments/1/replies", params: { message: 'oi' }, headers: token_headers, as: :json }
        end
      end

      expect(response).to have_http_status(:too_many_requests)
      expect(error_body).to include('kind' => 'rate_limited', 'retry_after' => 1)
      expect(a_request(:post, /replies/)).to have_been_made.once
    end
  end

  describe 'GET comments/:comment_id/replies' do
    it 'reads the first page (50) of replies, keeping only the account own replies' do
      own = { id: 'r1', text: 'oi', from: { id: '17841400000000000', username: 'loja' }, timestamp: '2026-10-31T12:00:05+0000', extra: 'x' }
      someone_else = { id: 'r2', text: 'oi', from: { id: '9', username: 'cliente' }, timestamp: '2026-10-31T12:00:06+0000' }
      without_author = { id: 'r3', text: 'oi' }
      stub_request(:get, %r{#{graph}/1789/replies}).with(query: hash_including(fields: 'id,text,from,timestamp', limit: '50'))
                                                   .to_return(graph_json(200, { data: [own, someone_else, without_author] }))

      get "#{base_path}/comments/1789/replies", headers: token_headers

      expect(response.parsed_body).to eq('data' => [{ 'id' => 'r1', 'text' => 'oi',
                                                      'from' => { 'id' => '17841400000000000', 'username' => 'loja' },
                                                      'timestamp' => '2026-10-31T12:00:05+0000' }])
    end

    it 'maps a read timeout to 503 unavailable (a read has no effect)' do
      stub_request(:get, /replies/).to_raise(Net::ReadTimeout)

      get "#{base_path}/comments/1789/replies", headers: token_headers

      expect(response).to have_http_status(:service_unavailable)
      expect(error_body['kind']).to eq('unavailable')
    end
  end

  describe 'media' do
    it 'lists media with limit/after and exposes the next cursor only when there is a next page' do
      stub_request(:get, %r{#{graph}/me/media}).with(query: hash_including(limit: '24', after: 'QVFIabc'))
                                               .to_return(graph_json(200, { data: [{ id: 'm1', media_product_type: 'REELS' }],
                                                                            paging: { cursors: { after: 'QVFInext' }, next: 'https://graph/next' } }))

      get "#{base_path}/media", params: { after: 'QVFIabc' }, headers: token_headers

      expect(response.parsed_body).to eq('data' => [{ 'id' => 'm1', 'media_product_type' => 'REELS' }], 'paging' => { 'after' => 'QVFInext' })
    end

    it 'returns paging.after null on the last page' do
      stub_request(:get, %r{#{graph}/me/media}).to_return(graph_json(200, { data: [], paging: { cursors: { after: 'QVFIend' } } }))

      get "#{base_path}/media", params: { limit: 10 }, headers: token_headers

      expect(response.parsed_body['paging']).to eq('after' => nil)
    end

    it 'rejects an invalid limit with 422' do
      get "#{base_path}/media", params: { limit: 500 }, headers: token_headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'reads one media and maps a missing one (100/33) to 404 not_found' do
      stub_request(:get, %r{#{graph}/179\?}).to_return(graph_json(200, { id: '179', caption: 'Promo', timestamp: '2026-10-30T10:00:00+0000' }))
      stub_request(:get, %r{#{graph}/404\?}).to_return(graph_json(400, { error: { code: 100, error_subcode: 33, message: 'does not exist' } }))

      get "#{base_path}/media/179", headers: token_headers
      expect(response.parsed_body).to include('id' => '179', 'caption' => 'Promo')

      get "#{base_path}/media/404", headers: token_headers
      expect(response).to have_http_status(:not_found)
      expect(error_body).to include('kind' => 'not_found', 'code' => 100, 'subcode' => 33)
    end
  end

  describe 'ice-breakers' do
    let(:items) { [{ question: 'Quais os horários?', payload: 'ib:3f2a' }] }

    it 'reads them flattened from the default locale' do
      profile = { data: [{ ice_breakers: [{ call_to_actions: [{ question: 'Hello?', payload: 'en' }], locale: 'en_US' },
                                          { call_to_actions: items, locale: 'default' }] }] }
      stub_request(:get, %r{#{graph}/me/messenger_profile}).with(query: hash_including(fields: 'ice_breakers', platform: 'instagram'))
                                                           .to_return(graph_json(200, profile))

      get "#{base_path}/ice-breakers", headers: token_headers

      expect(response.parsed_body).to eq('ice_breakers' => [{ 'question' => 'Quais os horários?', 'payload' => 'ib:3f2a' }])
    end

    it 'replaces them with the Graph shape (platform instagram, locale default) as JSON' do
      write = stub_request(:post, %r{#{graph}/me/messenger_profile})
              .with(body: { platform: 'instagram', ice_breakers: [{ call_to_actions: items, locale: 'default' }] }.to_json,
                    headers: { 'Content-Type' => 'application/json' })
              .to_return(graph_json(200, { result: 'success' }))

      put "#{base_path}/ice-breakers", params: { ice_breakers: items }, headers: token_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('ice_breakers' => [{ 'question' => 'Quais os horários?', 'payload' => 'ib:3f2a' }])
      expect(write).to have_been_requested.once
    end

    it 'validates up to 4 items, question up to 80 and payload up to 1000 characters' do
      put "#{base_path}/ice-breakers", params: { ice_breakers: Array.new(5) { items.first } }, headers: token_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      put "#{base_path}/ice-breakers", params: { ice_breakers: [{ question: 'q' * 81, payload: 'p' }] }, headers: token_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      put "#{base_path}/ice-breakers", params: { ice_breakers: [{ question: 'q', payload: 'p' * 1001 }] }, headers: token_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(a_request(:post, /messenger_profile/)).not_to have_been_made
    end

    it 'deletes them' do
      delete_request = stub_request(:delete, %r{#{graph}/me/messenger_profile})
                       .with(query: hash_including(fields: '["ice_breakers"]', platform: 'instagram'))
                       .to_return(graph_json(200, { result: 'success' }))

      delete "#{base_path}/ice-breakers", headers: token_headers

      expect(response.parsed_body).to eq('ice_breakers' => [])
      expect(delete_request).to have_been_requested.once
    end
  end

  describe 'GET users/:igsid' do
    it 'returns the follow fields' do
      user = { id: '555', username: 'cliente_x', name: 'Cliente', is_user_follow_business: true, is_business_follow_user: false, extra: 1 }
      stub_request(:get, %r{#{graph}/555\?}).with(query: hash_including(fields: 'name,username,is_user_follow_business,is_business_follow_user'))
                                            .to_return(graph_json(200, user))

      get "#{base_path}/users/555", headers: token_headers

      expect(response.parsed_body).to eq('id' => '555', 'username' => 'cliente_x', 'name' => 'Cliente',
                                         'is_user_follow_business' => true, 'is_business_follow_user' => false)
    end

    it 'maps the consent error (230) to 409 consent_required' do
      stub_request(:get, %r{#{graph}/555\?}).to_return(graph_json(400, { error: { code: 230, message: 'User consent is required' } }))

      get "#{base_path}/users/555", headers: token_headers

      expect(response).to have_http_status(:conflict)
      expect(error_body).to include('kind' => 'consent_required', 'code' => 230)
    end

    it 'maps an invalid token (190) to 403 reauthorization_required and flags the channel' do
      stub_request(:get, %r{#{graph}/555\?}).to_return(graph_json(400, { error: { code: 190, message: 'Invalid OAuth access token' } }))

      get "#{base_path}/users/555", headers: token_headers

      expect(response).to have_http_status(:forbidden)
      expect(error_body['kind']).to eq('reauthorization_required')
      expect(channel.reload).to be_reauthorization_required
    end

    it 'maps a missing permission (10) to 403 permission_denied and a Graph 5xx to 503 unavailable' do
      stub_request(:get, %r{#{graph}/10\?}).to_return(graph_json(400, { error: { code: 10, message: 'Permission denied' } }))
      stub_request(:get, %r{#{graph}/500\?}).to_return(graph_json(500, { error: { code: 2, message: 'Service temporarily unavailable' } }))

      get "#{base_path}/users/10", headers: token_headers
      expect(error_body['kind']).to eq('permission_denied')

      get "#{base_path}/users/500", headers: token_headers
      expect(response).to have_http_status(:service_unavailable)
      expect(error_body['kind']).to eq('unavailable')
    end
  end
end
