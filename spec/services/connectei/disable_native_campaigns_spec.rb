require 'rails_helper'

# [FORK CONNECTEI] modifications/024 — campanhas nativas desligadas em todas as contas.
RSpec.describe Connectei::DisableNativeCampaigns do
  subject(:service) { described_class.new }

  let(:defaults_name) { 'ACCOUNT_LEVEL_FEATURE_DEFAULTS' }
  let(:yaml_features) { YAML.safe_load(Rails.root.join('config/features.yml').read) }

  def defaults
    InstallationConfig.find_by(name: defaults_name)
  end

  def campaigns_entries
    defaults.value.select { |feature| feature['name'] == 'campaigns' }
  end

  describe 'existing accounts' do
    let!(:account) { create(:account) }
    let!(:other_account) { create(:account) }

    before do
      # outra feature na mesma coluna (feature_flags) e uma em feature_flags_ext_1
      account.enable_features!(:campaigns, :channel_website, :whatsapp_manual_transfer)
      other_account.enable_features!(:campaigns, :data_import)
    end

    it 'turns campaigns off on every account' do
      result = service.perform

      expect(result[:accounts_updated]).to eq(2)
      expect(account.reload.feature_enabled?(:campaigns)).to be(false)
      expect(other_account.reload.feature_enabled?(:campaigns)).to be(false)
    end

    it 'keeps every other feature bit untouched, in both flag columns' do
      ext_before = account.reload.feature_flags_ext_1
      other_ext_before = other_account.reload.feature_flags_ext_1

      service.perform

      expect(account.reload).to have_attributes(feature_channel_website?: true, feature_whatsapp_manual_transfer?: true)
      expect(account.feature_flags_ext_1).to eq(ext_before)
      expect(other_account.reload.feature_data_import?).to be(true)
      expect(other_account.feature_flags_ext_1).to eq(other_ext_before)
    end

    it 'clears only the campaigns bit from feature_flags' do
      column, mapping = Account.flag_mapping.find { |_column, flags| flags.key?(:feature_campaigns) }
      bit = mapping[:feature_campaigns]
      before = account.reload.public_send(column)

      service.perform

      expect(column).to eq('feature_flags')
      expect(account.reload.public_send(column)).to eq(before & ~bit)
    end

    it 'is idempotent' do
      service.perform
      flags_after_first = Account.order(:id).pluck(:feature_flags, :feature_flags_ext_1)
      config_after_first = defaults.reload.attributes.slice('serialized_value', 'updated_at')

      second = service.perform

      expect(second).to eq(default_changed: false, accounts_updated: 0)
      expect(Account.order(:id).pluck(:feature_flags, :feature_flags_ext_1)).to eq(flags_after_first)
      expect(defaults.reload.attributes.slice('serialized_value', 'updated_at')).to eq(config_after_first)
      expect(campaigns_entries.size).to eq(1)
    end
  end

  describe 'ACCOUNT_LEVEL_FEATURE_DEFAULTS' do
    it 'creates the row from config/features.yml with campaigns off when it is missing' do
      expect(defaults).to be_nil

      expect(service.perform[:default_changed]).to be(true)

      expect(defaults).to have_attributes(locked: true)
      expect(defaults.value.pluck('name')).to eq(yaml_features.pluck('name'))
      expect(campaigns_entries).to contain_exactly(hash_including('enabled' => false))
    end

    it 'changes only the campaigns entry and keeps the stored order and values' do
      stored = [
        { 'name' => 'reports', 'enabled' => false },
        { 'name' => 'campaigns', 'display_name' => 'Campaigns', 'enabled' => true },
        { 'name' => 'channel_email', 'enabled' => true }
      ]
      InstallationConfig.create!(name: defaults_name, value: stored, locked: true)

      service.perform

      expect(defaults.value).to eq([
                                     { 'name' => 'reports', 'enabled' => false },
                                     { 'name' => 'campaigns', 'display_name' => 'Campaigns', 'enabled' => false },
                                     { 'name' => 'channel_email', 'enabled' => true }
                                   ])
    end

    it 'appends a single campaigns entry when the stored row lacks it' do
      InstallationConfig.create!(name: defaults_name, value: [{ 'name' => 'reports', 'enabled' => true }], locked: true)

      service.perform
      service.perform

      expect(defaults.value.pluck('name')).to eq(%w[reports campaigns])
      expect(campaigns_entries).to contain_exactly(hash_including('enabled' => false))
    end

    context 'when a later sync resolves config/features.yml back to campaigns enabled: true' do
      # O features.yml do repositório já vem com campaigns desligado, então rodar o ConfigLoader
      # com ele não distingue "guardado vence" de "yml vence". Aqui o yml diz true de propósito.
      let(:config_dir) { Dir.mktmpdir }

      before do
        FileUtils.cp(Rails.root.join('config/installation_config.yml'), config_dir)
        enabled_yml = yaml_features.map { |f| f['name'] == 'campaigns' ? f.merge('enabled' => true) : f }
        File.write(File.join(config_dir, 'features.yml'), enabled_yml.to_yaml)

        InstallationConfig.create!(name: defaults_name, value: yaml_features.map { |f| f.merge('enabled' => true) }, locked: true)
        service.perform
      end

      after { FileUtils.remove_entry(config_dir) }

      it 'is not flipped back by the ConfigLoader that runs after db:migrate (reconcile_only_new)' do
        ConfigLoader.new.process(config_path: config_dir)

        expect(campaigns_entries).to contain_exactly(hash_including('enabled' => false))
      end

      it 'would be flipped back only by a full reconcile (reconcile_only_new: false)' do
        ConfigLoader.new.process(config_path: config_dir, reconcile_only_new: false)

        expect(campaigns_entries).to contain_exactly(hash_including('enabled' => true))
      end
    end

    it 'makes accounts created afterwards start with campaigns off' do
      service.perform

      new_account = create(:account)

      expect(new_account.reload.feature_enabled?(:campaigns)).to be(false)
      expect(new_account.feature_enabled?(:channel_email)).to be(true)
    end
  end

  it 'ships features.yml with campaigns off by default, for a fresh installation' do
    expect(yaml_features.find { |feature| feature['name'] == 'campaigns' }).to include('enabled' => false)
  end
end
