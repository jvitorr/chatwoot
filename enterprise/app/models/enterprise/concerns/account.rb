module Enterprise::Concerns::Account
  extend ActiveSupport::Concern

  included do
    store_accessor :settings, :conversation_required_attributes
    store_accessor :settings, :captain_document_auto_sync_enabled

    # Seed a scheduling baseline the moment auto-sync is enabled for an existing
    # account. Legacy documents have NULL last_sync_attempted_at, which the
    # scheduler interprets as "due immediately". Starting the cadence from
    # enable-time avoids an instant catch-up sweep across all old documents.
    after_update_commit :seed_captain_document_sync_schedule, if: :captain_document_auto_sync_just_enabled?

    has_many :sla_policies, dependent: :destroy_async
    has_many :applied_slas, dependent: :destroy_async
    has_many :custom_roles, dependent: :destroy_async
    has_many :agent_capacity_policies, dependent: :destroy_async

    has_many :captain_assistants, dependent: :destroy_async, class_name: 'Captain::Assistant'
    has_many :captain_assistant_responses, dependent: :destroy_async, class_name: 'Captain::AssistantResponse'
    has_many :captain_documents, dependent: :destroy_async, class_name: 'Captain::Document'
    has_many :captain_custom_tools, dependent: :destroy_async, class_name: 'Captain::CustomTool'

    has_many :copilot_threads, dependent: :destroy_async
    has_many :companies, dependent: :destroy_async
    has_many :voice_channels, dependent: :destroy_async, class_name: '::Channel::Voice'
    has_many :calls, dependent: :destroy_async

    has_one :saml_settings, dependent: :destroy_async, class_name: 'AccountSamlSettings'
  end

  private

  def captain_document_auto_sync_just_enabled?
    return false unless saved_change_to_captain_document_auto_sync_enabled?

    previous_value, current_value = saved_change_to_captain_document_auto_sync_enabled

    !ActiveModel::Type::Boolean.new.cast(previous_value) &&
      ActiveModel::Type::Boolean.new.cast(current_value)
  end

  def seed_captain_document_sync_schedule
    # Use Time.current as the scheduler baseline for existing documents. This
    # does not mean a sync happened now; it means the first auto-sync interval
    # starts now instead of from created_at/updated_at, which could make old
    # documents look immediately overdue.
    # rubocop:disable Rails/SkipsModelValidations
    captain_documents.where(status: :available, last_sync_attempted_at: nil)
                     .update_all(last_sync_attempted_at: Time.current)
    # rubocop:enable Rails/SkipsModelValidations
  end
end
