class Captain::Llm::HelpCenterCurationService < Captain::BaseTaskService
  RESPONSE_SCHEMA = Captain::Llm::HelpCenterCurationSchema
  MAX_LINKS_IN_PROMPT = 200

  pattr_initialize [:account!, :links!]

  def perform
    response = make_api_call(model: curation_model, messages: messages, schema: RESPONSE_SCHEMA)
    return response if response[:error]

    response.merge(message: extract_payload(response[:message]))
  end

  private

  def extract_payload(message)
    return { categories: [], articles: [] } if message.blank?

    data = message.is_a?(Hash) ? message.deep_symbolize_keys : {}
    {
      categories: Array(data[:categories]),
      articles: Array(data[:articles])
    }
  end

  def messages
    [
      { role: 'system', content: system_prompt },
      { role: 'user', content: user_prompt }
    ]
  end

  def system_prompt
    <<~PROMPT
      You are curating a small help center for a company's customer-support widget.
      You will be given a list of pages discovered on the company's website.
      Pick the 10-12 pages that would make the most useful help-center articles for end users:
      docs, FAQs, how-tos, troubleshooting, getting-started, account/billing help, product guides.
      Skip marketing/landing pages, blog posts, login, pricing tiers, legal, careers, press, investor pages.
      Group your picks into 3-5 short, reusable categories.
      Use the URL paths and page titles to judge relevance — do not invent URLs.

      For each article, output one URL by default. Use 2 or 3 URLs ONLY when the pages
      clearly cover the SAME topic from complementary angles. When in doubt, use one URL.

      Strong overlap signals (multi-URL is appropriate):
        - One URL is a topic overview, another is a provider/variant-specific guide on
          the same topic ("SSO setup" + "SSO with Okta"; "Webhooks overview" + "Webhook
          payload reference").
        - One URL is an FAQ for a topic, another is the deep-dive that the FAQ links to.
        - A how-to is split across multiple URLs by step or platform.

      NOT overlap (use separate articles, one URL each):
        - Topics that share a category but cover different things ("Setting up SSO" and
          "Setting up MFA" are both auth — still separate articles).
        - One URL is a marketing page about a feature, another is the feature's docs —
          skip the marketing page entirely.
        - Pages that are merely thematically related ("Pricing" and "Plan limits" — pick
          one).

      Almost every article on a typical site has one URL. Multi-URL is the exception, not the norm.

      Write all category names, category descriptions, and article titles in #{locale_name}.
      The input page titles and descriptions may be in another language; translate the labels you emit into #{locale_name}.
      Keep URLs unchanged.
    PROMPT
  end

  def user_prompt
    parts = [
      "Company: #{account.name}",
      ("Description: #{brand_info[:description]}" if brand_info[:description].present?),
      ("Industries: #{industries_text}" if industries_text.present?),
      'Discovered pages (url — title — description):',
      formatted_links
    ].compact
    parts.join("\n")
  end

  def locale_name
    code = account.locale.to_s
    LANGUAGES_CONFIG.values.find { |v| v[:iso_639_1_code] == code }&.dig(:name) || code.presence || 'English (en)'
  end

  def formatted_links
    Array(links).first(MAX_LINKS_IN_PROMPT).map do |link|
      data = link.is_a?(Hash) ? link.deep_symbolize_keys : {}
      "- #{data[:url]} — #{data[:title].to_s.strip} — #{data[:description].to_s.strip}"
    end.join("\n")
  end

  def brand_info
    @brand_info ||= (account.custom_attributes['brand_info'] || {}).deep_symbolize_keys
  end

  def industries_text
    Array(brand_info[:industries]).filter_map { |i| i.is_a?(Hash) ? i[:industry] : i }.join(', ').presence
  end

  def event_name
    'help_center_curation'
  end

  def llm_credential
    @llm_credential ||= system_llm_credential
  end

  def captain_tasks_enabled?
    true
  end

  # Onboarding curation runs on the operator's OpenAI key; it should not
  # debit the customer's captain_responses quota.
  def counts_toward_usage?
    false
  end

  def curation_model
    'gpt-4.1'
  end

  def build_follow_up_context?
    false
  end
end
