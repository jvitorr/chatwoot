# Connectei — ver modifications/024.
#
# Escopos que a conta do Instagram concedeu no OAuth feito pelo ERP (mod 003).
# Decide se o canal assina o campo `comments` do webhook: pedir esse campo sem
# `instagram_business_manage_comments` concedido faz a Meta recusar a inscrição
# inteira. Fica persistido no canal para que QUALQUER re-subscribe (reconexão,
# PATCH da mod 003, rake connectei:instagram:resubscribe) preserve os campos.
class AddConnecteiGrantedScopesToChannelInstagram < ActiveRecord::Migration[7.1]
  def change
    add_column :channel_instagram, :connectei_granted_scopes, :string, array: true, default: [], null: false
  end
end
