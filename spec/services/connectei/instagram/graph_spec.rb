require 'rails_helper'

# [FORK CONNECTEI] modifications/028
describe Connectei::Instagram::Graph do
  describe '.base_url' do
    it 'defaults to the production Graph host' do
      with_modified_env INSTAGRAM_GRAPH_BASE_URL: nil do
        expect(described_class.base_url).to eq('https://graph.instagram.com')
      end
    end

    it 'reads INSTAGRAM_GRAPH_BASE_URL straight from the environment, without a trailing slash' do
      with_modified_env INSTAGRAM_GRAPH_BASE_URL: 'http://ig-stub.local:4010/' do
        expect(described_class.base_url).to eq('http://ig-stub.local:4010')
      end
    end

    it 'falls back to the default when the variable is blank' do
      with_modified_env INSTAGRAM_GRAPH_BASE_URL: '  ' do
        expect(described_class.base_url).to eq('https://graph.instagram.com')
      end
    end

    it 'never persists the base url into installation_configs (env must keep winning)' do
      with_modified_env INSTAGRAM_GRAPH_BASE_URL: 'http://ig-stub.local:4010' do
        described_class.base_url
      end

      expect(InstallationConfig.where(name: 'INSTAGRAM_GRAPH_BASE_URL')).to be_empty
    end
  end

  describe '.versioned_base_url' do
    # O cache do GlobalConfig vive no Redis (MockRedis nos specs), que não é
    # desfeito pela transação do exemplo: sem limpar, a versão vaza para os
    # specs seguintes.
    after { GlobalConfig.clear_cache }

    it 'combines the host with INSTAGRAM_API_VERSION' do
      InstallationConfig.where(name: 'INSTAGRAM_API_VERSION').first_or_create!(value: 'v23.0')
      GlobalConfig.clear_cache

      with_modified_env INSTAGRAM_GRAPH_BASE_URL: 'http://ig-stub.local:4010' do
        expect(described_class.versioned_base_url).to eq('http://ig-stub.local:4010/v23.0')
      end
    end

    it 'uses v22.0 when no version is configured' do
      with_modified_env INSTAGRAM_GRAPH_BASE_URL: nil do
        expect(described_class.versioned_base_url).to eq('https://graph.instagram.com/v22.0')
      end
    end
  end

  it 'exposes 5s open / 15s read timeouts' do
    expect(described_class::TIMEOUTS).to eq(open_timeout: 5, read_timeout: 15)
  end

  # Toda chamada à Graph do Instagram respeita INSTAGRAM_GRAPH_BASE_URL (é o que
  # deixa o E2E e a carga apontarem para um stub).
  describe 'call sites honoring INSTAGRAM_GRAPH_BASE_URL' do
    let(:stub_host) { 'http://ig-stub.local:4010' }
    let(:account) { create(:account) }
    let!(:channel) { create(:channel_instagram, account: account, instagram_id: 'ig-business-1') }
    let(:inbox) { channel.inbox }

    # O canal nasce (e assina o webhook) ANTES de trocar o host: o factory stuba o
    # host de produção. Só a ação sob teste roda com o stub configurado.
    def on_stub_host(&)
      with_modified_env(INSTAGRAM_GRAPH_BASE_URL: stub_host, &)
    end

    it 'subscribes and unsubscribes the webhook on the configured host, with explicit timeouts' do
      subscribe = stub_request(:post, %r{\A#{stub_host}/v22\.0/ig-business-1/subscribed_apps}).to_return(status: 200, body: '{}')
      unsubscribe = stub_request(:delete, %r{\A#{stub_host}/v22\.0/ig-business-1/subscribed_apps}).to_return(status: 200, body: '{}')
      allow(HTTParty).to receive(:post).and_call_original

      on_stub_host do
        channel.subscribe
        channel.unsubscribe
      end

      expect(subscribe).to have_been_requested.once
      expect(unsubscribe).to have_been_requested.once
      expect(HTTParty).to have_received(:post).with(anything, hash_including(open_timeout: 5, read_timeout: 15))
    end

    it 'sends messages through the configured host, with explicit timeouts' do
      send_request = stub_request(:post, %r{\A#{stub_host}/v22\.0/ig-business-1/messages})
                     .to_return(status: 200, body: { message_id: 'mid-1' }.to_json, headers: { 'Content-Type' => 'application/json' })
      allow(HTTParty).to receive(:post).and_call_original
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'igsid-1')
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      message = create(:message, message_type: :outgoing, account: account, inbox: inbox, conversation: conversation, content: 'oi')

      on_stub_host { Instagram::SendOnInstagramService.new(message: message).perform }

      expect(send_request).to have_been_requested.once
      expect(HTTParty).to have_received(:post).with(%r{\A#{stub_host}/}, hash_including(open_timeout: 5, read_timeout: 15))
      expect(message.reload.source_id).to eq('mid-1')
    end

    it 'fetches the user profile through the configured host' do
      profile = stub_request(:get, %r{\A#{stub_host}/v22\.0/igsid-42\?})
                .to_return(status: 200, body: { id: 'igsid-42', name: 'Ana', username: 'ana' }.to_json,
                           headers: { 'Content-Type' => 'application/json' })
      messaging = {
        sender: { id: 'igsid-42' }, recipient: { id: 'ig-business-1' }, timestamp: 1_730_376_000_000,
        message: { mid: 'mid-profile', text: 'oi' }
      }.with_indifferent_access

      on_stub_host { Instagram::MessageText.new(messaging, channel).perform }

      expect(profile).to have_been_requested.once
      expect(inbox.contacts.last.additional_attributes['social_instagram_user_name']).to eq('ana')
    end

    it 'fetches the mentioned story through the configured host' do
      story = stub_request(:get, %r{\A#{stub_host}/v22\.0/mid-mention\?.*fields=story,from})
              .to_return(status: 200, body: { story: { mention: { id: 'story-1' } }, from: { username: 'ana' } }.to_json)
      stub_request(:get, 'https://www.example.com/story.jpeg').to_return(status: 200, body: 'img', headers: { 'Content-Type' => 'image/jpeg' })
      contact = create(:contact, account: account)
      create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'igsid-7')
      messaging = {
        sender: { id: 'igsid-7' }, recipient: { id: 'ig-business-1' },
        message: { mid: 'mid-mention', attachments: [{ type: 'story_mention', payload: { url: 'https://www.example.com/story.jpeg' } }] }
      }.with_indifferent_access

      on_stub_host { Messages::Instagram::MessageBuilder.new(messaging, inbox).perform }

      expect(story).to have_been_requested.once
      expect(inbox.messages.last.content_attributes['story_id']).to eq('story-1')
    end

    it 'refreshes the long-lived token through the configured host' do
      refresh = stub_request(:get, %r{\A#{stub_host}/refresh_access_token\?})
                .to_return(status: 200, body: { access_token: 'renewed', expires_in: 5_184_000 }.to_json)
      channel.update_columns(expires_at: 3.days.from_now, updated_at: 2.days.ago) # rubocop:disable Rails/SkipsModelValidations

      token = on_stub_host { Instagram::RefreshOauthTokenService.new(channel: channel.reload).access_token }

      expect(refresh).to have_been_requested.once
      expect(token).to eq('renewed')
    end

    it 'exchanges and reads the OAuth user on the configured host' do
      exchange = stub_request(:get, %r{\A#{stub_host}/access_token\?})
                 .to_return(status: 200, body: { access_token: 'long', expires_in: 10 }.to_json)
      me = stub_request(:get, %r{\A#{stub_host}/v22\.0/me\?}).to_return(status: 200, body: { user_id: '1' }.to_json)
      concern = Class.new { include InstagramConcern }.new

      on_stub_host do
        concern.send(:exchange_for_long_lived_token, 'short')
        concern.send(:fetch_instagram_user_details, 'long')
      end

      expect(exchange).to have_been_requested.once
      expect(me).to have_been_requested.once
    end
  end
end
