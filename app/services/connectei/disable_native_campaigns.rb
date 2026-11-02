# [FORK CONNECTEI] Ver modifications/024-desliga-campanhas-nativas.md
#
# Desliga a feature `campaigns` (campanhas nativas do chat) em todas as contas e no
# default das contas novas. O Connectei nunca usa campanha nativa: quem dispara
# campanha é o ERP, direto na Graph API. Com a feature ligada, a 4.19 enfileira um
# `Campaigns::UpdateRecipientStatusJob` (até 5 tentativas, fila `low`) para cada status
# de WhatsApp de wamid órfão, ou seja, para cada status de disparo do ERP.
#
# Idempotente: rodar de novo não altera nada. Não reabilita nada no `down` da migration.
class Connectei::DisableNativeCampaigns
  FEATURE_NAME = 'campaigns'.freeze
  FLAG = :feature_campaigns
  DEFAULTS_CONFIG_NAME = 'ACCOUNT_LEVEL_FEATURE_DEFAULTS'.freeze
  BATCH_SIZE = 1000

  # Devolve quantas contas tiveram o bit desligado e se o default mudou.
  def perform
    default_changed = disable_default
    GlobalConfig.clear_cache

    { default_changed: default_changed, accounts_updated: disable_on_existing_accounts }
  end

  private

  # Contas criadas daqui em diante leem o default em `enable_default_features`
  # (Featurable, before_create). Só o `enabled` da entrada `campaigns` muda: as outras
  # entradas e a ordem guardada ficam como estão.
  def disable_default
    config = InstallationConfig.find_or_initialize_by(name: DEFAULTS_CONFIG_NAME)
    current = config.new_record? ? feature_list_from_yaml : Array(config.value)
    updated = with_campaigns_disabled(current)
    return false if !config.new_record? && updated == current

    config.value = updated
    config.locked = true if config.new_record?
    config.save!
    true
  end

  def with_campaigns_disabled(features)
    return features + [campaigns_entry_from_yaml.merge('enabled' => false)] if features.none? { |feature| campaigns?(feature) }

    features.map { |feature| campaigns?(feature) ? feature.merge('enabled' => false) : feature }
  end

  def campaigns?(feature)
    feature['name'] == FEATURE_NAME
  end

  # Sem a linha (instalação nova cujas migrations rodam antes do ConfigLoader), cria a
  # mesma lista que o ConfigLoader criaria; ele depois encontra a linha e não a sobrescreve.
  def feature_list_from_yaml
    YAML.safe_load(Rails.root.join('config/features.yml').read)
  end

  def campaigns_entry_from_yaml
    feature_list_from_yaml.find { |feature| campaigns?(feature) }
  end

  # O bit vem do mapeamento do FlagShihTzu (posição em config/features.yml), nunca fixo.
  # update_all direto: os callbacks de Account não dependem de `campaigns`.
  def disable_on_existing_accounts
    column, mapping = Account.flag_mapping.find { |_column, flags| flags.key?(FLAG) }
    bit = mapping.fetch(FLAG)
    quoted_column = Account.connection.quote_column_name(column)

    updated = 0
    Account.where("#{quoted_column} & #{bit} <> 0").in_batches(of: BATCH_SIZE) do |batch|
      updated += batch.update_all("#{quoted_column} = #{quoted_column} & ~CAST(#{bit} AS bigint)") # rubocop:disable Rails/SkipsModelValidations
    end
    updated
  end
end
