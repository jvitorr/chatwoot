require 'rails_helper'

describe BaseMarkdownRenderer do
  let(:renderer) { described_class.new }

  def render_markdown(markdown)
    doc = CommonMarker.render_doc(markdown, :DEFAULT)
    renderer.render(doc)
  end

  describe '#image' do
    context 'when image has a numeric height' do
      it 'normalises bare integers to px' do
        markdown = '![Sample Title](https://example.com/image.jpg?cw_image_height=100)'
        expect(render_markdown(markdown)).to include('<img src="https://example.com/image.jpg?cw_image_height=100" style="height: 100px;" />')
      end

      it 'preserves explicit px values' do
        markdown = '![Sample Title](https://example.com/image.jpg?cw_image_height=24px)'
        expect(render_markdown(markdown)).to include('<img src="https://example.com/image.jpg?cw_image_height=24px" style="height: 24px;" />')
      end
    end

    context 'when image has height=auto' do
      it 'renders the auto keyword' do
        markdown = '![Sample Title](https://example.com/image.jpg?cw_image_height=auto)'
        expect(render_markdown(markdown)).to include('style="height: auto;"')
      end
    end

    context 'when image does not have a height' do
      it 'renders the img tag without the height attribute' do
        markdown = '![Sample Title](https://example.com/image.jpg)'
        expect(render_markdown(markdown)).to include('<img src="https://example.com/image.jpg" />')
      end
    end

    context 'when cw_image_height contains an attribute-breakout payload' do
      it 'drops the style attribute instead of injecting it' do
        markdown = '![x](https://example.com/image.jpg?cw_image_height=100%22%20onerror%3Dalert%281%29%20x%3D%22)'
        expect(render_markdown(markdown)).not_to include('style=')
      end
    end

    context 'when cw_image_height is otherwise non-conforming' do
      it 'drops the style attribute' do
        markdown = '![x](https://example.com/image.jpg?cw_image_height=10em)'
        expect(render_markdown(markdown)).not_to include('style=')
      end
    end

    context 'when image has an invalid URL' do
      it 'renders the img tag without crashing' do
        markdown = '![Sample Title](invalid_url)'
        expect { render_markdown(markdown) }.not_to raise_error
      end
    end
  end
end
