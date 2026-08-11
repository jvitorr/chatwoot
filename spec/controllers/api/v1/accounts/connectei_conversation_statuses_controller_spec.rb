require 'rails_helper'

# Connectei — ver modifications/017.
RSpec.describe 'Connectei Conversation Statuses API', type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }

  def bulk(conversations, user: admin)
    post "/api/v1/accounts/#{account.id}/connectei-conversation-statuses",
         params: { conversations: conversations }, headers: user.create_new_auth_token, as: :json
  end

  describe 'POST /connectei-conversation-statuses' do
    it 'requires authentication' do
      post "/api/v1/accounts/#{account.id}/connectei-conversation-statuses", as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'applies the status to every conversation in the batch' do
      a = create(:conversation, account: account, inbox: inbox, status: :open)
      b = create(:conversation, account: account, inbox: inbox, status: :open)

      bulk([{ id: a.display_id, status: 'resolved' }, { id: b.display_id, status: 'resolved' }])

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['updated']).to eq(2)
      expect(a.reload.status).to eq('resolved')
      expect(b.reload.status).to eq('resolved')
    end

    # O caminho do modelo é o que mantém os invariantes do próprio Chatwoot:
    # `execute_after_update_commit_callbacks` dispara `create_activity` e
    # `notify_status_change`. Um `update_all` pularia os dois — e também não
    # tocaria `updated_at`, que é o sinal observável DENTRO da transação do
    # spec (os callbacks `after_commit` não disparam com
    # `use_transactional_fixtures`, então contar mensagem de atividade aqui
    # nunca funcionaria, mesmo com o código certo).
    it 'goes through the model, not update_all' do
      conversation = create(:conversation, account: account, inbox: inbox, status: :open)
      antes = conversation.updated_at

      travel_to(1.minute.from_now) do
        bulk([{ id: conversation.display_id, status: 'resolved' }])
      end

      expect(conversation.reload.updated_at).to be > antes
      expect(conversation.status).to eq('resolved')
    end

    # A migração precisa poder rodar de novo. Reescrever o que já está no alvo
    # geraria mensagem de atividade a cada execução, sujando o histórico.
    it 'counts already-correct conversations as unchanged and does not rewrite them' do
      conversation = create(:conversation, account: account, inbox: inbox, status: :resolved)
      before_count = conversation.messages.count

      bulk([{ id: conversation.display_id, status: 'resolved' }])

      expect(response.parsed_body['unchanged']).to eq(1)
      expect(response.parsed_body['updated']).to eq(0)
      expect(conversation.reload.messages.count).to eq(before_count)
    end

    it 'is idempotent: running the same batch twice leaves the same state' do
      conversation = create(:conversation, account: account, inbox: inbox, status: :open)

      bulk([{ id: conversation.display_id, status: 'resolved' }])
      after_first = conversation.reload.messages.count

      bulk([{ id: conversation.display_id, status: 'resolved' }])

      expect(response.parsed_body['unchanged']).to eq(1)
      expect(conversation.reload.status).to eq('resolved')
      # A 2ª execução não pode acrescentar mensagem de atividade nenhuma.
      expect(conversation.messages.count).to eq(after_first)
    end

    # Limite de inquilino: conversa de outra conta não é tocada nem "quase".
    it 'never touches a conversation from another account' do
      foreign_inbox = create(:inbox, account: other_account)
      foreign = create(:conversation, account: other_account, inbox: foreign_inbox, status: :open)

      bulk([{ id: foreign.display_id, status: 'resolved' }])

      expect(foreign.reload.status).to eq('open')
      expect(response.parsed_body['failed'].first['error']).to eq('not found in this account')
    end

    it 'reports an unknown conversation instead of failing the whole batch' do
      ok = create(:conversation, account: account, inbox: inbox, status: :open)

      bulk([{ id: ok.display_id, status: 'resolved' }, { id: 999_999, status: 'resolved' }])

      expect(response.parsed_body['updated']).to eq(1)
      expect(response.parsed_body['failed'].length).to eq(1)
      expect(ok.reload.status).to eq('resolved')
    end

    it 'rejects an invalid status without touching the conversation' do
      conversation = create(:conversation, account: account, inbox: inbox, status: :open)

      bulk([{ id: conversation.display_id, status: 'banana' }])

      expect(response.parsed_body['updated']).to eq(0)
      expect(response.parsed_body['failed'].first['error']).to include('invalid status')
      expect(conversation.reload.status).to eq('open')
    end

    it 'rejects an empty payload' do
      bulk([])

      expect(response).to have_http_status(:unprocessable_entity)
    end

    # Corte silencioso aqui seria o pior desfecho: o chamador acharia que
    # migrou tudo e metade da caixa de entrada voltaria aberta.
    it 'rejects a batch over the cap instead of truncating it' do
      oversized = Array.new(501) { |i| { id: i + 1, status: 'resolved' } }

      bulk(oversized)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to include('batch too large')
    end
  end
end
