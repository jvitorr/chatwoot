class Captain::Llm::ArticleWriterService < Captain::BaseTaskService
  RESPONSE_SCHEMA = Captain::Llm::ArticleWriterSchema
  SOURCE_MAX_LENGTH = 60_000

  pattr_initialize [:account!, :source_markdown!, :source_url!, { hint_title: nil }]

  def perform
    response = make_api_call(model: writer_model, messages: messages, schema: RESPONSE_SCHEMA)
    return response if response[:error]

    response.merge(message: extract_payload(response[:message]))
  end

  private

  def extract_payload(message)
    return {} if message.blank?

    data = message.is_a?(Hash) ? message.deep_symbolize_keys : {}
    {
      title: data[:title].to_s.strip,
      description: data[:description].to_s.strip,
      content: data[:content].to_s.strip
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
      You are rewriting one web page into a clean help-center article for a customer-support knowledge base.
      Preserve the substance: keep instructions, steps, code samples, configuration, troubleshooting, and FAQs intact.
      Strip marketing copy, navigation breadcrumbs, "share this page" footers, repeated CTAs, and links to unrelated pages.
      Output well-formatted Markdown — use headings, lists, and code fences where appropriate.
      The body must stay under 18000 characters. If the source is longer, trim repetition and tangents before cutting steps or critical detail.
      Never invent content the source does not support.

      Write the title, description, and body in #{locale_name}.
      If the source page is in another language, translate as you rewrite — do not copy source-language text into the output.
      Code samples, command-line examples, API field names, and proper nouns stay in their original form.
    PROMPT
  end

  def user_prompt
    parts = [
      "Source URL: #{source_url}",
      ("Suggested title (you may rewrite): #{hint_title}" if hint_title.present?),
      'Source page (Markdown):',
      source_markdown.to_s.truncate(SOURCE_MAX_LENGTH, omission: "\n\n[source truncated for length]")
    ].compact
    parts.join("\n\n")
  end

  def locale_name
    code = account.locale.to_s
    LANGUAGES_CONFIG.values.find { |v| v[:iso_639_1_code] == code }&.dig(:name) || code.presence || 'English (en)'
  end

  def event_name
    'article_writer'
  end

  def llm_credential
    @llm_credential ||= system_llm_credential
  end

  def captain_tasks_enabled?
    true
  end

  # Rewrite runs on the operator's OpenAI key during onboarding; should not
  # debit the customer's captain_responses quota.
  def counts_toward_usage?
    false
  end

  def writer_model
    @writer_model ||= InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || GPT_MODEL
  end

  def build_follow_up_context?
    false
  end
end
