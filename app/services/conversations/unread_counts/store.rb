class Conversations::UnreadCounts::Store
  class << self
    def base_ready?(account_id)
      Redis::Alfred.exists?(base_ready_key(account_id))
    end

    def assignment_ready?(account_id)
      Redis::Alfred.exists?(assignment_ready_key(account_id))
    end

    def mark_base_ready!(account_id)
      Redis::Alfred.set(base_ready_key(account_id), Time.current.to_i)
    end

    def mark_assignment_ready!(account_id)
      Redis::Alfred.set(assignment_ready_key(account_id), Time.current.to_i)
    end

    def clear_account!(account_id)
      delete_matching("#{account_prefix(account_id)}::*")
    end

    def clear_assignment!(account_id)
      assignment_key_patterns(account_id).each { |pattern| delete_matching(pattern) }
    end

    def add_base_membership(account_id:, inbox_id:, label_ids:, conversation_id:)
      add_to_sets(base_keys(account_id, inbox_id, label_ids), conversation_id)
    end

    def remove_base_membership(account_id:, inbox_ids:, label_ids:, conversation_id:)
      keys = Array(inbox_ids).flat_map { |inbox_id| base_keys(account_id, inbox_id, label_ids) }
      remove_from_sets(keys, conversation_id)
    end

    def add_assignment_membership(account_id:, inbox_id:, label_ids:, assignee_id:, conversation_id:)
      add_to_sets(assignment_keys(account_id, inbox_id, label_ids, assignee_id), conversation_id)
    end

    def remove_assignment_membership(account_id:, inbox_ids:, label_ids:, assignee_ids:, conversation_id:)
      keys = Array(inbox_ids).flat_map do |inbox_id|
        Array(assignee_ids).flat_map { |assignee_id| assignment_keys(account_id, inbox_id, label_ids, assignee_id) }
      end
      remove_from_sets(keys, conversation_id)
    end

    def add_memberships(account_id:, memberships:, assignment: false)
      return if memberships.blank?

      Redis::Alfred.pipelined do |pipeline|
        memberships.each do |membership|
          keys = if assignment
                   assignment_keys(account_id, membership[:inbox_id], membership[:label_ids], membership[:assignee_id])
                 else
                   base_keys(account_id, membership[:inbox_id], membership[:label_ids])
                 end

          keys.each { |key| pipeline.sadd(key, membership[:conversation_id]) }
        end
      end
    end

    def counts_for_keys(keys)
      keys = keys.compact_blank
      return {} if keys.blank?

      counts = Redis::Alfred.pipelined do |pipeline|
        keys.each { |key| pipeline.scard(key) }
      end
      keys.zip(counts).to_h
    end

    def memberships_for_keys(keys, conversation_id)
      keys = keys.compact_blank
      return {} if keys.blank?

      memberships = Redis::Alfred.pipelined do |pipeline|
        keys.each { |key| pipeline.sismember(key, conversation_id) }
      end
      keys.zip(memberships.map { |membership| membership == true || membership == 1 }).to_h
    end

    def inbox_key(account_id, inbox_id)
      format(Redis::Alfred::UNREAD_CONVERSATIONS_INBOX, account_id: account_id, inbox_id: inbox_id)
    end

    def label_inbox_key(account_id, label_id, inbox_id)
      format(Redis::Alfred::UNREAD_CONVERSATIONS_LABEL_INBOX, account_id: account_id, label_id: label_id, inbox_id: inbox_id)
    end

    def inbox_unassigned_key(account_id, inbox_id)
      format(Redis::Alfred::UNREAD_CONVERSATIONS_INBOX_UNASSIGNED, account_id: account_id, inbox_id: inbox_id)
    end

    def inbox_assignee_key(account_id, inbox_id, user_id)
      format(Redis::Alfred::UNREAD_CONVERSATIONS_INBOX_ASSIGNEE, account_id: account_id, inbox_id: inbox_id, user_id: user_id)
    end

    def label_inbox_unassigned_key(account_id, label_id, inbox_id)
      format(
        Redis::Alfred::UNREAD_CONVERSATIONS_LABEL_INBOX_UNASSIGNED,
        account_id: account_id,
        label_id: label_id,
        inbox_id: inbox_id
      )
    end

    def label_inbox_assignee_key(account_id, label_id, inbox_id, user_id)
      format(
        Redis::Alfred::UNREAD_CONVERSATIONS_LABEL_INBOX_ASSIGNEE,
        account_id: account_id,
        label_id: label_id,
        inbox_id: inbox_id,
        user_id: user_id
      )
    end

    private

    def base_ready_key(account_id)
      format(Redis::Alfred::UNREAD_CONVERSATIONS_BASE_READY, account_id: account_id)
    end

    def assignment_ready_key(account_id)
      format(Redis::Alfred::UNREAD_CONVERSATIONS_ASSIGNMENT_READY, account_id: account_id)
    end

    def account_prefix(account_id)
      format(Redis::Alfred::UNREAD_CONVERSATIONS_ACCOUNT_PREFIX, account_id: account_id)
    end

    def base_keys(account_id, inbox_id, label_ids)
      [inbox_key(account_id, inbox_id)] + Array(label_ids).map { |label_id| label_inbox_key(account_id, label_id, inbox_id) }
    end

    def assignment_keys(account_id, inbox_id, label_ids, assignee_id)
      if assignee_id.present?
        [inbox_assignee_key(account_id, inbox_id, assignee_id)] +
          Array(label_ids).map { |label_id| label_inbox_assignee_key(account_id, label_id, inbox_id, assignee_id) }
      else
        [inbox_unassigned_key(account_id, inbox_id)] +
          Array(label_ids).map { |label_id| label_inbox_unassigned_key(account_id, label_id, inbox_id) }
      end
    end

    def add_to_sets(keys, conversation_id)
      write_to_sets(keys) { |pipeline, key| pipeline.sadd(key, conversation_id) }
    end

    def remove_from_sets(keys, conversation_id)
      write_to_sets(keys) { |pipeline, key| pipeline.srem(key, conversation_id) }
    end

    def write_to_sets(keys)
      keys = keys.compact_blank
      return if keys.blank?

      Redis::Alfred.pipelined do |pipeline|
        keys.each { |key| yield(pipeline, key) }
      end
    end

    def delete_matching(pattern)
      Redis::Alfred.scan_each(match: pattern, count: 1000) do |key|
        Redis::Alfred.delete(key)
      end
    end

    def assignment_key_patterns(account_id)
      prefix = account_prefix(account_id)
      [
        assignment_ready_key(account_id),
        "#{prefix}::INBOX::*::UNASSIGNED",
        "#{prefix}::INBOX::*::ASSIGNEE::*",
        "#{prefix}::LABEL::*::INBOX::*::UNASSIGNED",
        "#{prefix}::LABEL::*::INBOX::*::ASSIGNEE::*"
      ]
    end
  end
end
