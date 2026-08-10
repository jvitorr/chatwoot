require 'rails_helper'

RSpec.describe RoomChannel do
  let!(:contact_inbox) { create(:contact_inbox) }
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }

  before do
    stub_connection
  end

  it 'subscribes to a stream when pubsub_token is provided' do
    subscribe(pubsub_token: contact_inbox.pubsub_token)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(contact_inbox.pubsub_token)
  end

  it 'subscribes to a stream when pubsub_token is provided for user' do
    subscribe(user_id: user.id, pubsub_token: user.pubsub_token, account_id: account.id)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(user.pubsub_token)
    expect(subscription).to have_stream_for("account_#{account.id}")
  end

  # Connectei — ver modifications/013.
  context 'with the connectei subscription hardening' do
    it 'subscribes an agent using only the pubsub token' do
      # Sem isto o upstream trata token de agente como token de contato e a
      # inscrição falha — que era o caso silencioso observado em produção.
      subscribe(pubsub_token: user.pubsub_token)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_for(user.pubsub_token)
      expect(subscription).to have_stream_for("account_#{account.id}")
    end

    it 'subscribes an agent when account_id is omitted and there is a single account' do
      subscribe(user_id: user.id, pubsub_token: user.pubsub_token)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_for(user.pubsub_token)
    end

    it 'REJECTS an unknown token instead of leaving the client waiting forever' do
      subscribe(pubsub_token: 'token-que-nao-existe')

      expect(subscription).to be_rejected
    end

    it 'rejects when the token does not match the informed user' do
      other_user = create(:user, account: account)

      subscribe(user_id: other_user.id, pubsub_token: user.pubsub_token, account_id: account.id)

      expect(subscription).to be_rejected
    end
  end
end
