class BaseMarkdownRenderer < CommonMarker::HtmlRenderer
  def image(node)
    src, title = extract_img_attributes(node)
    height = extract_image_height(src)

    render_img_tag(src, title, height)
  end

  private

  def extract_img_attributes(node)
    [
      escape_href(node.url),
      escape_html(node.title)
    ]
  end

  def extract_image_height(src)
    raw = parse_query_params(src)['cw_image_height']&.first

    case raw
    when 'auto' then 'auto'
    when /\A(\d+)(?:px)?\z/ then "#{Regexp.last_match(1)}px"
    end
  end

  def parse_query_params(url)
    parsed_url = URI.parse(url)
    CGI.parse(parsed_url.query || '')
  rescue URI::InvalidURIError
    {}
  end

  def render_img_tag(src, title, height = nil)
    # Use inline style instead of the HTML height attribute: email clients and
    # the in-app Letter view both run images through CSS (e.g. prose /
    # lettersanitizer's `img { height: auto }`) which overrides presentational
    # attributes. Inline style has higher specificity and survives.
    plain do
      out(%(<img src="#{src}"))
      out(' alt="', :children, '"')
      out(%( title="#{title}")) if title.present?
      out(%( style="height: #{height};")) if height
      out(' />')
    end
  end
end
