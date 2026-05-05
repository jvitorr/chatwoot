class Onboarding::HelpCenterCreationService
  DEFAULT_PORTAL_COLOR = '#1f93ff'.freeze

  def initialize(account, user)
    @account = account
    @user = user
  end

  def perform
    existing = existing_portal
    if existing
      Rails.logger.info "[HelpCenterCreation] Reusing existing portal #{existing.id} for account #{@account.id}"
      return existing
    end

    @account.portals.create!(portal_attributes)
  rescue StandardError => e
    Rails.logger.error "[HelpCenterCreation] #{e.message}"
    nil
  end

  private

  def existing_portal
    @account.portals.first
  end

  def portal_attributes
    {
      name: portal_name,
      slug: generate_slug,
      color: portal_color,
      page_title: portal_name,
      header_text: header_text,
      homepage_link: homepage_link,
      channel_web_widget_id: web_widget_channel_id,
      config: { default_locale: locale, allowed_locales: [locale] }
    }.compact
  end

  def brand_info
    @brand_info ||= (@account.custom_attributes['brand_info'] || {}).deep_symbolize_keys
  end

  def portal_name
    brand_info[:title].presence || @account.name
  end

  def portal_color
    hex = brand_info[:colors]&.first&.dig(:hex)
    hex.to_s.match?(/\A#\h{6}\z/) ? hex : DEFAULT_PORTAL_COLOR
  end

  def header_text
    brand_info[:slogan].presence || brand_info[:description].presence
  end

  def homepage_link
    @account.domain.presence || brand_info[:domain].presence
  end

  def web_widget_channel_id
    @account.inboxes.find_by(channel_type: 'Channel::WebWidget')&.channel_id
  end

  def locale
    @account.locale.presence || 'en'
  end

  def generate_slug
    base = @account.name.to_s.parameterize
    base.present? ? "#{base}-#{SecureRandom.hex(4)}" : "portal-#{SecureRandom.hex(8)}"
  end
end
