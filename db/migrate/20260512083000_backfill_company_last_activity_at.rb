class BackfillCompanyLastActivityAt < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    execute <<~SQL.squish
      UPDATE companies
      SET last_activity_at = contact_activity.last_activity_at
      FROM (
        SELECT contacts.company_id, MAX(COALESCE(conversations.last_activity_at, conversations.created_at)) AS last_activity_at
        FROM contacts
        INNER JOIN conversations ON conversations.contact_id = contacts.id
        WHERE contacts.company_id IS NOT NULL
        GROUP BY contacts.company_id
      ) contact_activity
      WHERE companies.id = contact_activity.company_id
        AND (companies.last_activity_at IS NULL OR companies.last_activity_at < contact_activity.last_activity_at)
    SQL
  end

  def down; end
end
