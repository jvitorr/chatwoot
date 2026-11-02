class Whatsapp::TemplateProcessorService
  pattr_initialize [:channel!, :template_params, :message]

  def call
    return [nil, nil, nil, nil] if template_params.blank?

    process_template_with_params
  end

  private

  def process_template_with_params
    [
      template_params['name'],
      template_params['namespace'],
      template_params['language'],
      processed_templates_params
    ]
  end

  def find_template
    channel.message_templates.find do |t|
      t['name'] == template_params['name'] &&
        t['language']&.downcase == template_params['language']&.downcase &&
        t['status']&.downcase == 'approved'
    end
  end

  def processed_templates_params
    template = find_template

    if template.present?
      # Convert legacy format to enhanced format before processing
      converter = Whatsapp::TemplateParameterConverterService.new(template_params, template)
      normalized_params = converter.normalize_to_enhanced

      return process_enhanced_template_params(template, normalized_params['processed_params'])
    end

    # [FORK CONNECTEI] Ver modifications/002-fallback-template-nao-sincronizado.md
    # Template not in the synced cache yet (e.g. just created in Meta). Only
    # trust caller-provided enhanced params when the request explicitly carries
    # a parameter_format hint, so legacy callers still get the safe nil result.
    # As DUAS condições são necessárias: remover a de parameter_format reabre a
    # regressão da spec upstream do caso "template inexistente".
    return if template_params['parameter_format'].blank? || template_params['processed_params'].blank?

    process_enhanced_template_params(template, template_params['processed_params'])
  end

  def process_enhanced_template_params(template, processed_params = nil)
    processed_params ||= template_params['processed_params']
    parameter_format = resolve_parameter_format(template)
    components = []

    components.concat(process_header_components(processed_params, template, parameter_format))
    components.concat(process_body_components(processed_params, parameter_format))
    components.concat(process_footer_components(processed_params))
    components.concat(process_button_components(processed_params))

    @template_params = components
  end

  # [FORK CONNECTEI] modifications/002 — the caller-provided format (from Meta,
  # forwarded in template_params) wins so named/positional binding works even
  # when the synced template is stale or missing; falls back to the cached
  # template's format.
  def resolve_parameter_format(template)
    requested = template_params.is_a?(Hash) ? template_params['parameter_format'] : nil
    requested.presence || template&.dig('parameter_format')
  end

  def process_header_components(processed_params, template, parameter_format)
    return [] if processed_params['header'].blank?

    header_params = build_header_params(processed_params['header'], template, parameter_format)
    header_params.present? ? [{ type: 'header', parameters: header_params }] : []
  end

  def build_header_params(header_data, template, parameter_format)
    # [FORK CONNECTEI] modifications/002 — no synced template (fallback path):
    # there is no HEADER component to read the format from, so keep the
    # pre-4.19 key-driven header building instead of indexing into nil.
    return build_header_params_without_template(header_data) if template.blank?

    header_component = template['components']&.find { |component| component['type'] == 'HEADER' }
    return build_text_header_params(header_data, parameter_format) if header_component&.dig('format') == 'TEXT'

    build_media_header_params(header_data)
  end

  def build_text_header_params(header_data, parameter_format)
    header_data.filter_map do |key, value|
      build_text_parameter(key, value, parameter_format) if value.present?
    end
  end

  def build_media_header_params(header_data)
    return [] if header_data['media_url'].blank? || header_data['media_type'].blank?

    media_param = parameter_builder.build_media_parameter(header_data['media_url'], header_data['media_type'], header_data['media_name'])
    media_param ? [media_param] : []
  end

  # [FORK CONNECTEI] modifications/002 — header building used before 4.19 (when
  # the template is not in the synced cache): media_url + media_type becomes a
  # media parameter, any other key becomes a text parameter.
  def build_header_params_without_template(header_data)
    header_data.filter_map do |key, value|
      next if value.blank? || %w[media_type media_name].include?(key)
      next parameter_builder.build_parameter(value) unless key == 'media_url' && header_data['media_type'].present?

      parameter_builder.build_media_parameter(value, header_data['media_type'], header_data['media_name'])
    end
  end

  def process_body_components(processed_params, parameter_format)
    return [] if processed_params['body'].blank?

    body_parameters = processed_params['body']
    body_parameters = body_parameters.sort_by { |key, _value| key.to_i } unless parameter_format == 'NAMED'

    body_params = body_parameters.filter_map do |key, value|
      next if value.blank?

      build_text_parameter(key, value, parameter_format)
    end

    body_params.present? ? [{ type: 'body', parameters: body_params }] : []
  end

  def build_text_parameter(key, value, parameter_format)
    return parameter_builder.build_named_parameter(key, value) if parameter_format == 'NAMED'

    parameter_builder.build_parameter(value)
  end

  def process_footer_components(processed_params)
    return [] if processed_params['footer'].blank?

    footer_params = processed_params['footer'].filter_map do |_, value|
      next if value.blank?

      parameter_builder.build_parameter(value)
    end

    footer_params.present? ? [{ type: 'footer', parameters: footer_params }] : []
  end

  def process_button_components(processed_params)
    return [] if processed_params['buttons'].blank?

    button_params = processed_params['buttons'].filter_map.with_index do |button, index|
      next if button.blank?

      if button['type'] == 'url' || button['parameter'].present?
        {
          type: 'button',
          sub_type: button['type'] || 'url',
          index: index,
          parameters: [parameter_builder.build_button_parameter(button)]
        }
      end
    end

    button_params.compact
  end

  def parameter_builder
    @parameter_builder ||= Whatsapp::PopulateTemplateParametersService.new
  end
end
