class Whatsapp::IdentifierSyncService
  pattr_initialize [:contact_inbox!, :contact]

  def perform(bsuid: nil, parent_bsuid: nil, username: nil)
    update_contact_inbox(bsuid, parent_bsuid)
    update_contact(username)
  end

  private

  def update_contact_inbox(bsuid, parent_bsuid)
    attributes = {
      whatsapp_bsuid: normalize_bsuid(bsuid),
      whatsapp_parent_bsuid: normalize_bsuid(parent_bsuid)
    }.compact

    update_record(contact_inbox, attributes)
  end

  def update_contact(username)
    return if contact.blank?

    username = normalize_username(username)
    return if username.blank?

    contact.update!(additional_attributes: additional_attributes_with_username(username))
  end

  def update_record(record, attributes)
    attributes = attributes.compact.reject { |key, value| record.public_send(key) == value }
    return if attributes.blank?

    record.update!(attributes)
  end

  def normalize_bsuid(value)
    value.to_s.delete_prefix('whatsapp:').presence
  end

  def normalize_username(value)
    value.to_s.sub(/\A@+/, '').presence
  end

  def additional_attributes_with_username(username)
    attributes = contact.additional_attributes.deep_dup
    social_profiles = attributes['social_profiles'] || {}
    social_profiles['whatsapp'] = username

    attributes.merge(
      'social_profiles' => social_profiles,
      'social_whatsapp_user_name' => username
    )
  end
end
