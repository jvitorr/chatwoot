class Call < ApplicationRecord
  # All valid call statuses
  STATUSES = %w[ringing in_progress completed no_answer failed].freeze
  # Statuses where the call is finished and won't change again
  TERMINAL_STATUSES = %w[completed no_answer failed].freeze

  enum :provider, { twilio: 0, whatsapp: 1 }
  enum :direction, { incoming: 0, outgoing: 1 }

  belongs_to :account
  belongs_to :inbox
  belongs_to :conversation
  belongs_to :message, optional: true
  belongs_to :accepted_by_agent, class_name: 'User', optional: true

  has_one_attached :recording

  validates :provider_call_id, presence: true
  validates :provider, presence: true
  validates :direction, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where.not(status: TERMINAL_STATUSES) }
  scope :ringing, -> { where(status: 'ringing') }

  def ringing?
    status == 'ringing'
  end

  def in_progress?
    status == 'in_progress'
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  # Frontend-facing direction label: incoming→inbound, outgoing→outbound
  def direction_label
    incoming? ? 'inbound' : 'outbound'
  end

  def sdp_offer
    meta&.dig('sdp_offer')
  end

  def ice_servers
    meta&.dig('ice_servers') || []
  end

  def recording_url
    return unless recording.attached?

    Rails.application.routes.url_helpers.rails_blob_path(recording, only_path: true)
  end
end
