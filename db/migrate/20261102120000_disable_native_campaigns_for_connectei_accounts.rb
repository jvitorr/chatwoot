# [FORK CONNECTEI] Ver modifications/024-desliga-campanhas-nativas.md
# Desliga as campanhas nativas do chat em todas as contas e no default das contas novas.
# Fora de transação, como a 20261014152259 do upstream: o default é salvo primeiro, e as
# contas são atualizadas em lotes que fazem commit cada um.
class DisableNativeCampaignsForConnecteiAccounts < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    Connectei::DisableNativeCampaigns.new.perform
  end

  def down
    # Sem volta automática: o Connectei nunca usa campanha nativa. Para religar numa conta,
    # use o super admin (feature "Campaigns") depois de ler a modificação 024.
  end
end
