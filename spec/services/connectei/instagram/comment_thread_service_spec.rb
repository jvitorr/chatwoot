require 'rails_helper'

# [FORK CONNECTEI] modifications/026 — comentário e DM simultâneos não abrem duas conversas.
#
# Concorrência de verdade exige duas conexões com dados COMMITADOS: este grupo
# desliga a transação do exemplo e limpa o banco (DELETE) no fim.
describe Connectei::Instagram::CommentThreadService do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram, account: account, instagram_id: "ig-#{SecureRandom.hex(4)}") }
  let(:inbox) { channel.inbox }
  let(:igsid) { "igsid-#{SecureRandom.hex(4)}" }
  let!(:contact_inbox) { create(:contact_inbox, inbox: inbox, source_id: igsid) }

  # DELETE, não TRUNCATE: o TRUNCATE reinicia as sequências, os ids voltam a 1 e
  # chaves que o MockRedis guarda por id (ex.: reautorização do canal) vazam para
  # os specs seguintes.
  after { DatabaseCleaner.clean_with(:deletion) }

  # Outra conexão segura o advisory lock (como um DM em processamento) e cria a
  # conversa; o COMMIT só sai `hold` segundos depois de o teste seguir.
  def in_flight_conversation(hold:, status: :open)
    locked = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          Connectei::Instagram::ThreadLock.acquire!(inbox.id, igsid)
          Conversation.create!(account_id: account.id, inbox_id: inbox.id, contact_id: contact_inbox.contact_id,
                               contact_inbox_id: contact_inbox.id, status: status)
          locked << true
          sleep(hold)
        end
      end
    end
    locked.pop
    thread
  end

  it 'waits for a DM that holds the thread lock and reuses its conversation instead of creating another' do
    dm = in_flight_conversation(hold: 0.5)

    result = described_class.new(inbox: inbox, igsid: igsid, username: 'cliente_x').perform
    dm.join

    expect(result[:created]).to be(false)
    expect(Conversation.where(inbox_id: inbox.id).count).to eq(1)
  end

  it 'makes a DM that arrives during the comment-thread reuse the pending conversation' do
    stub_request(:get, /graph\.instagram\.com/).to_return(status: 200, body: { id: igsid, username: 'cliente_x' }.to_json)
    comment_thread = in_flight_conversation(hold: 0.5, status: :pending)
    messaging = { sender: { id: igsid }, recipient: { id: channel.instagram_id }, message: { mid: "mid-#{SecureRandom.hex(4)}", text: 'oi' } }

    Messages::Instagram::MessageBuilder.new(messaging.with_indifferent_access, inbox).perform
    comment_thread.join

    expect(Conversation.where(inbox_id: inbox.id).count).to eq(1)
    expect(Message.where(inbox_id: inbox.id).pluck(:conversation_id).uniq).to eq(Conversation.where(inbox_id: inbox.id).pluck(:id))
  end

  it 'uses a stable advisory key per (inbox, igsid)' do
    key = Connectei::Instagram::ThreadLock.advisory_key(inbox.id, igsid)

    expect(Connectei::Instagram::ThreadLock.advisory_key(inbox.id, igsid)).to eq(key)
    expect(Connectei::Instagram::ThreadLock.advisory_key(inbox.id, "#{igsid}-2")).not_to eq(key)
    expect(key).to be_between(-(2**63), (2**63) - 1)
  end
end
