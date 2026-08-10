# Connectei — ver modifications/012.
#
# A listagem do painel ordena por `last_activity_at` e filtra por conta/inbox.
# Não existia NENHUM índice em `conversations.last_activity_at`: cada página
# pedia um sort completo do conjunto filtrado. Com a operação crescendo, esse
# sort é o primeiro gargalo — e ele aparece igual no `/conversations/filter`
# oficial, que ordena pela mesma coluna.
class AddConnecteiConversationListingIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    # Ordenação da lista dentro de uma loja (conta + canais + recência).
    add_index :conversations, [:account_id, :inbox_id, :last_activity_at],
              name: 'idx_conversations_account_inbox_last_activity',
              order: { last_activity_at: :desc },
              algorithm: :concurrently,
              if_not_exists: true

    # Quadro por atendente sem filtro de canal — o índice existente
    # (account_id, inbox_id, status, assignee_id) só serve com inbox no WHERE.
    add_index :conversations, [:account_id, :status, :assignee_id],
              name: 'idx_conversations_account_status_assignee',
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :conversations, name: 'idx_conversations_account_inbox_last_activity', if_exists: true
    remove_index :conversations, name: 'idx_conversations_account_status_assignee', if_exists: true
  end
end
