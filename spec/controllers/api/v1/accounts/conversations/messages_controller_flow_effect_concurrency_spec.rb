require 'rails_helper'

# [FORK CONNECTEI] modifications/027b — dois POST simultâneos com a mesma `flow_effect_key`.
#
# Precisa de duas conexões com dados COMMITADOS: sem a transação do exemplo, com
# limpeza do banco no fim.
RSpec.describe 'Conversation Messages API — concurrent flow_effect_key', type: :request do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account) }

  before { create(:inbox_member, inbox: inbox, user: agent) }
  # DELETE, não TRUNCATE: o TRUNCATE reinicia as sequências, os ids voltam a 1 e
  # chaves que o MockRedis guarda por id (ex.: reautorização do canal) vazam para
  # os specs seguintes.
  after { DatabaseCleaner.clean_with(:deletion) }

  it 'makes the second request wait for the first commit and return its message' do
    lock_key = Digest::SHA256.digest("connectei:flow-effect:#{conversation.id}:fx:race")[0, 8].unpack1('q>')
    locked = Queue.new
    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key})")
          create(:message, conversation: conversation, inbox: inbox, account: account, message_type: :outgoing, content: 'Oi',
                           content_attributes: { flow_effect_key: 'fx:race' })
          locked << true
          sleep 0.5
        end
      end
    end
    locked.pop

    post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id),
         params: { content: 'Oi', content_attributes: { flow_effect_key: 'fx:race' } },
         headers: { api_access_token: agent.access_token.token }, as: :json
    first.join

    expect(response).to have_http_status(:ok)
    expect(Message.where(conversation_id: conversation.id).count).to eq(1)
    expect(response.parsed_body['id']).to eq(Message.find_by(conversation_id: conversation.id).id)
  end
end
