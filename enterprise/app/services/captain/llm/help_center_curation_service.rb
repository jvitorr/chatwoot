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
    @curation_model ||= InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || GPT_MODEL
  end

  def build_follow_up_context?
    false
  end
end
