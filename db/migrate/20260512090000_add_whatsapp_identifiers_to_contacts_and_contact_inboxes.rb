class AddWhatsappIdentifiersToContactsAndContactInboxes < ActiveRecord::Migration[7.0]
  def change
    add_column :contact_inboxes, :whatsapp_bsuid, :string
    add_column :contact_inboxes, :whatsapp_parent_bsuid, :string

    add_index :contact_inboxes, [:inbox_id, :whatsapp_bsuid],
              unique: true,
              where: 'whatsapp_bsuid IS NOT NULL',
              name: 'index_contact_inboxes_on_inbox_id_and_whatsapp_bsuid'
    add_index :contact_inboxes, [:inbox_id, :whatsapp_parent_bsuid],
              where: 'whatsapp_parent_bsuid IS NOT NULL',
              name: 'index_contact_inboxes_on_inbox_id_and_whatsapp_parent_bsuid'
  end
end
