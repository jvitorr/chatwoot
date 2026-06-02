require 'rails_helper'

describe Whatsapp::TemplateProcessorService do
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
      let(:channel) { double(message_templates: [template]) }
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
      let(:channel) { double(message_templates: [template]) }
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
      let(:channel) { double(message_templates: []) }
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
      let(:channel) { double(message_templates: [template]) }
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
  end
end
