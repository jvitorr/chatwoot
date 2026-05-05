class Conversations::UnreadCounts::Counter
  MANAGE_ALL_PERMISSION = 'conversation_manage'.freeze
  UNASSIGNED_PERMISSION = 'conversation_unassigned_manage'.freeze
  PARTICIPATING_PERMISSION = 'conversation_participating_manage'.freeze

  attr_reader :account, :user

  def initialize(account:, user:)
    @account = account
    @user = user
  end

  def perform
    ensure_base_cache!
    return empty_counts if permission_mode == :none

    ensure_assignment_cache! if assignment_mode?

    {
      inboxes: unread_inbox_counts,
      labels: unread_label_counts
    }
  end

  private

  def ensure_base_cache!
    ::Conversations::UnreadCounts::Builder.new(account).build_base! unless store.base_ready?(account.id)
  end

  def ensure_assignment_cache!
    ::Conversations::UnreadCounts::Builder.new(account).build_assignment! unless store.assignment_ready?(account.id)
  end

  def unread_inbox_counts
    counts_for_grouped_keys(visible_inbox_ids.index_with { |inbox_id| inbox_keys_for_mode(inbox_id) })
  end

  def unread_label_counts
    keys_by_id = Hash.new { |hash, key| hash[key] = [] }
    sidebar_label_ids.each do |label_id|
      visible_inbox_ids.each do |inbox_id|
        keys_by_id[label_id].concat(label_inbox_keys_for_mode(label_id, inbox_id))
      end
    end

    counts_for_grouped_keys(keys_by_id)
  end

  def inbox_keys_for_mode(inbox_id)
    case permission_mode
    when :base
      [store.inbox_key(account.id, inbox_id)]
    when :unassigned_and_mine
      [store.inbox_unassigned_key(account.id, inbox_id), store.inbox_assignee_key(account.id, inbox_id, user.id)]
    when :mine
      [store.inbox_assignee_key(account.id, inbox_id, user.id)]
    end
  end

  def label_inbox_keys_for_mode(label_id, inbox_id)
    case permission_mode
    when :base
      [store.label_inbox_key(account.id, label_id, inbox_id)]
    when :unassigned_and_mine
      [
        store.label_inbox_unassigned_key(account.id, label_id, inbox_id),
        store.label_inbox_assignee_key(account.id, label_id, inbox_id, user.id)
      ]
    when :mine
      [store.label_inbox_assignee_key(account.id, label_id, inbox_id, user.id)]
    end
  end

  def counts_for_grouped_keys(keys_by_id)
    counts_by_key = store.counts_for_keys(keys_by_id.values.flatten)

    keys_by_id.each_with_object({}) do |(id, keys), result|
      count = keys.sum { |key| counts_by_key[key].to_i }
      result[id.to_s] = count if count.positive?
    end
  end

  def assignment_mode?
    %i[unassigned_and_mine mine].include?(permission_mode)
  end

  def permission_mode
    @permission_mode ||=
      if !custom_role_agent? || permissions.include?(MANAGE_ALL_PERMISSION)
        :base
      elsif permissions.include?(UNASSIGNED_PERMISSION)
        :unassigned_and_mine
      elsif permissions.include?(PARTICIPATING_PERMISSION)
        :mine
      else
        :none
      end
  end

  def custom_role_agent?
    account_user&.agent? && account_user.custom_role_id.present?
  end

  def permissions
    account_user&.permissions || []
  end

  def account_user
    @account_user ||= account.account_users.find_by(user_id: user.id)
  end

  def visible_inbox_ids
    @visible_inbox_ids ||= if account_user&.administrator?
                             account.inboxes.pluck(:id)
                           else
                             user.inboxes.where(account_id: account.id).pluck(:id)
                           end
  end

  def sidebar_label_ids
    @sidebar_label_ids ||= account.labels.where(show_on_sidebar: true).pluck(:id)
  end

  def empty_counts
    { inboxes: {}, labels: {} }
  end

  def store
    ::Conversations::UnreadCounts::Store
  end
end
