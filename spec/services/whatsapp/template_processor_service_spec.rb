require 'rails_helper'

describe Whatsapp::TemplateProcessorService do
  subject(:processed_components) do
    described_class.new(channel: channel, template_params: template_params).call.last
  end

  let(:channel) { instance_double(Channel::Whatsapp, message_templates: [template]) }
  let(:template_params) do
    {
      'name' => template['name'],
      'language' => template['language'],
      'processed_params' => { 'header' => header_params }
    }
  end

  context 'with a positional text header' do
    let(:template) do
      {
        'name' => 'positional_header',
        'language' => 'en_US',
        'status' => 'APPROVED',
        'parameter_format' => 'POSITIONAL',
        'components' => [{ 'type' => 'HEADER', 'format' => 'TEXT', 'text' => 'Welcome {{1}}' }]
      }
    end
    let(:header_params) { { '1' => 'Jane' } }

    it 'builds a positional text parameter' do
      expect(processed_components).to eq([
                                           {
                                             type: 'header',
                                             parameters: [{ type: 'text', text: 'Jane' }]
                                           }
                                         ])
    end
  end

  context 'with a named text header' do
    let(:template) do
      {
        'name' => 'named_header',
        'language' => 'en_US',
        'status' => 'APPROVED',
        'parameter_format' => 'NAMED',
        'components' => [{ 'type' => 'HEADER', 'format' => 'TEXT', 'text' => "Welcome {{#{parameter_name}}}" }]
      }
    end
    let(:header_params) { { parameter_name => 'Jane' } }

    %w[customer_name media_type media_name].each do |name|
      context "when the parameter is #{name}" do
        let(:parameter_name) { name }

        it 'preserves the parameter name' do
          expect(processed_components).to eq([
                                               {
                                                 type: 'header',
                                                 parameters: [{ type: 'text', parameter_name: parameter_name, text: 'Jane' }]
                                               }
                                             ])
        end
      end
    end
  end

  context 'with positional body parameters' do
    let(:template) do
      {
        'name' => 'positional_body',
        'language' => 'en_US',
        'status' => 'APPROVED',
        'parameter_format' => 'POSITIONAL',
        'components' => [{ 'type' => 'BODY', 'text' => '{{1}} / {{2}}' }]
      }
    end
    let(:template_params) do
      {
        'name' => template['name'],
        'language' => template['language'],
        'processed_params' => {
          'body' => {
            '2' => 'Bob',
            '1' => 'Alice'
          }
        }
      }
    end

    it 'orders parameters by their positional key' do
      expect(processed_components).to eq([
                                           {
                                             type: 'body',
                                             parameters: [
                                               { type: 'text', text: 'Alice' },
                                               { type: 'text', text: 'Bob' }
                                             ]
                                           }
                                         ])
    end
  end

  context 'with a media header' do
    let(:template) do
      {
        'name' => 'document_header',
        'language' => 'en_US',
        'status' => 'APPROVED',
        'parameter_format' => 'POSITIONAL',
        'components' => [{ 'type' => 'HEADER', 'format' => 'DOCUMENT' }]
      }
    end
    let(:header_params) do
      {
        'media_url' => 'https://example.com/report.pdf',
        'media_type' => 'document',
        'media_name' => 'report.pdf'
      }
    end

    it 'uses media metadata to build the attachment parameter' do
      expect(processed_components).to eq([
                                           {
                                             type: 'header',
                                             parameters: [
                                               {
                                                 type: 'document',
                                                 document: {
                                                   link: 'https://example.com/report.pdf',
                                                   filename: 'report.pdf'
                                                 }
                                               }
                                             ]
                                           }
                                         ])
    end
  end

  context 'with a static button before a dynamic button' do
    let(:template) do
      {
        'name' => 'offer', 'language' => 'en_US', 'status' => 'APPROVED',
        'components' => [
          { 'type' => 'BODY', 'text' => 'Your offer' },
          { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'QUICK_REPLY', 'text' => 'Thanks' }, { 'type' => 'COPY_CODE' }] }
        ]
      }
    end
    let(:template_params) do
      {
        'name' => 'offer', 'language' => 'en_US',
        'processed_params' => { 'buttons' => [nil, { 'type' => 'copy_code', 'parameter' => 'WELCOME' }] }
      }
    end

    it 'preserves the dynamic button index through normalization and payload generation' do
      expect(processed_components).to eq([
                                           { type: 'button', sub_type: 'copy_code', index: 1,
                                             parameters: [{ type: 'coupon_code', coupon_code: 'WELCOME' }] }
                                         ])
    end
  end

  # [FORK CONNECTEI] modifications/002-fallback-template-nao-sincronizado.md
  describe 'parameter format resolution and the unsynced-template fallback' do
    def process(channel:, template_params:)
      described_class.new(channel: channel, template_params: template_params, message: nil).call
    end

    def body_parameters(components)
      components.find { |c| c[:type] == 'body' }[:parameters]
    end

    describe '#call' do
      context 'when the synced template declares NAMED parameter_format' do
        let(:template) do
          {
            'name' => 'garantia_lente_arranhada',
            'language' => 'pt_BR',
            'status' => 'approved',
            'parameter_format' => 'NAMED',
            'components' => [{ 'type' => 'BODY', 'text' => 'Olá {{nome}}!' }]
          }
        end
        let(:channel) { instance_double(Channel::Whatsapp, message_templates: [template]) }
        let(:template_params) do
          {
            'name' => 'garantia_lente_arranhada',
            'language' => 'pt_BR',
            'processed_params' => { 'body' => { 'nome' => 'João' } }
          }
        end

        it 'binds the value to the named parameter' do
          _, _, _, components = process(channel: channel, template_params: template_params)
          expect(body_parameters(components)).to eq([{ type: 'text', parameter_name: 'nome', text: 'João' }])
        end
      end

      context 'when the request carries parameter_format but the cached template does not' do
        let(:template) do
          {
            'name' => 'garantia_lente_arranhada',
            'language' => 'pt_BR',
            'status' => 'approved',
            'components' => [{ 'type' => 'BODY', 'text' => 'Olá {{nome}}!' }]
          }
        end
        let(:channel) { instance_double(Channel::Whatsapp, message_templates: [template]) }
        let(:template_params) do
          {
            'name' => 'garantia_lente_arranhada',
            'language' => 'pt_BR',
            'parameter_format' => 'NAMED',
            'processed_params' => { 'body' => { 'nome' => 'João' } }
          }
        end

        it 'uses the request format and still builds named parameters' do
          _, _, _, components = process(channel: channel, template_params: template_params)
          expect(body_parameters(components)).to eq([{ type: 'text', parameter_name: 'nome', text: 'João' }])
        end
      end

      context 'when the template has not been synced into the channel cache yet' do
        let(:channel) { instance_double(Channel::Whatsapp, message_templates: []) }
        let(:template_params) do
          {
            'name' => 'brand_new_template',
            'language' => 'pt_BR',
            'parameter_format' => 'NAMED',
            'processed_params' => { 'body' => { 'nome' => 'João' } }
          }
        end

        it 'builds named parameters from the request without requiring a sync' do
          _, _, _, components = process(channel: channel, template_params: template_params)
          expect(body_parameters(components)).to eq([{ type: 'text', parameter_name: 'nome', text: 'João' }])
        end
      end

      context 'when the template uses POSITIONAL parameters' do
        let(:template) do
          {
            'name' => 'positional_template',
            'language' => 'pt_BR',
            'status' => 'approved',
            'parameter_format' => 'POSITIONAL',
            'components' => [{ 'type' => 'BODY', 'text' => 'Olá {{1}}!' }]
          }
        end
        let(:channel) { instance_double(Channel::Whatsapp, message_templates: [template]) }
        let(:template_params) do
          {
            'name' => 'positional_template',
            'language' => 'pt_BR',
            'parameter_format' => 'POSITIONAL',
            'processed_params' => { 'body' => { '1' => 'João' } }
          }
        end

        it 'binds the value positionally without parameter_name' do
          _, _, _, components = process(channel: channel, template_params: template_params)
          expect(body_parameters(components)).to eq([{ type: 'text', text: 'João' }])
        end
      end

      context 'when an unsynced template carries a text header' do
        let(:channel) { instance_double(Channel::Whatsapp, message_templates: []) }
        let(:template_params) do
          {
            'name' => 'brand_new_template',
            'language' => 'pt_BR',
            'parameter_format' => 'POSITIONAL',
            'processed_params' => { 'header' => { '1' => 'Ótica Central' }, 'body' => { '1' => 'João' } }
          }
        end

        it 'builds the header as a text parameter without reading the missing template' do
          _, _, _, components = process(channel: channel, template_params: template_params)
          expect(components).to eq([
                                     { type: 'header', parameters: [{ type: 'text', text: 'Ótica Central' }] },
                                     { type: 'body', parameters: [{ type: 'text', text: 'João' }] }
                                   ])
        end
      end

      context 'when an unsynced template carries a media header' do
        let(:channel) { instance_double(Channel::Whatsapp, message_templates: []) }
        let(:template_params) do
          {
            'name' => 'brand_new_template',
            'language' => 'pt_BR',
            'parameter_format' => 'POSITIONAL',
            'processed_params' => {
              'header' => { 'media_url' => 'https://example.com/report.pdf', 'media_type' => 'document', 'media_name' => 'report.pdf' }
            }
          }
        end

        it 'builds the media parameter from the request' do
          _, _, _, components = process(channel: channel, template_params: template_params)
          expect(components).to eq([
                                     {
                                       type: 'header',
                                       parameters: [
                                         { type: 'document', document: { link: 'https://example.com/report.pdf', filename: 'report.pdf' } }
                                       ]
                                     }
                                   ])
        end
      end
    end
  end
end
