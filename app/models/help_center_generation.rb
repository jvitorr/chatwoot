# == Schema Information
#
# Table name: help_center_generations
#
#  id                :bigint           not null, primary key
#  articles_finished :integer          default(0), not null
#  finished_at       :datetime
#  plan              :jsonb
#  skip_reason       :text
#  started_at        :datetime
#  status            :integer          default(0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#  portal_id         :bigint           not null
#
# Indexes
#
#  index_help_center_generations_on_account_id  (account_id)
#  index_help_center_generations_on_portal_id   (portal_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (portal_id => portals.id)
#
class HelpCenterGeneration < ApplicationRecord
  belongs_to :account
  belongs_to :portal

  enum :status, { pending: 0, curating: 1, generating: 2, completed: 3, skipped: 4 }

  def terminal?
    completed? || skipped?
  end

  def planned_total
    plan&.dig('articles')&.size.to_i
  end

  def all_finished?
    articles_finished >= planned_total
  end
end
