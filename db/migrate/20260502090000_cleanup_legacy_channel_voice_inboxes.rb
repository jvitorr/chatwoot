class CleanupLegacyChannelVoiceInboxes < ActiveRecord::Migration[7.1]
  # Inboxes whose channel_type column still says 'Channel::Voice' became
  # orphans after 20260326120001_drop_channel_voice.rb dropped both the
  # channel_voice table and the model class. The polymorphic
  # `belongs_to :channel` lookup on those rows fails to constantize
  # `Channel::Voice`, crashing the inbox serializer with
  # `uninitialized constant Channel::Voice`.
  #
  # Delete the orphan inboxes and their dependents via raw SQL so we
  # bypass the polymorphic load that would crash inside Rails callbacks.
  def up
    legacy_ids = ActiveRecord::Base.connection
                                   .exec_query("SELECT id FROM inboxes WHERE channel_type = 'Channel::Voice'")
                                   .rows.flatten

    return if legacy_ids.empty?

    say_with_time "Cleaning up #{legacy_ids.size} legacy Channel::Voice inbox(es): #{legacy_ids.inspect}" do
      delete_dependents(legacy_ids)
      execute("DELETE FROM inboxes WHERE id IN (#{legacy_ids.join(',')})")
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # Tables with an inbox_id FK that need clearing before the inbox row is removed.
  # Order matters where one table FKs another (messages → conversations).
  DEPENDENT_TABLES = %w[
    messages
    conversations
    contact_inboxes
    inbox_members
    agent_bot_inboxes
    campaigns
    webhooks
    integrations_hooks
    inbox_assignment_policies
  ].freeze

  def delete_dependents(inbox_ids)
    in_clause = inbox_ids.join(',')
    DEPENDENT_TABLES.each do |table|
      next unless ActiveRecord::Base.connection.table_exists?(table)
      next unless ActiveRecord::Base.connection.column_exists?(table, :inbox_id)

      execute("DELETE FROM #{table} WHERE inbox_id IN (#{in_clause})")
    end
  end
end
