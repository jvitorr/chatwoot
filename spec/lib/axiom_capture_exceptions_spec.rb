require 'rails_helper'
require Rails.root.join('lib/axiom_capture_exceptions.rb').to_s

describe AxiomCaptureExceptions do
  let(:env) { Rack::MockRequest.env_for('/orders') }

  def middleware_raising(exception)
    described_class.new(->(_env) { raise exception })
  end

  it 'passes successful responses through untouched' do
    app = described_class.new(->(_env) { [200, {}, ['ok']] })

    expect(Axiom::Reporter).not_to receive(:report)
    expect(app.call(env)).to eq [200, {}, ['ok']]
  end

  it 'reports the exception and re-raises it' do
    exception = StandardError.new('boom')
    expect(Axiom::Reporter).to receive(:report).with(exception, request: instance_of(ActionDispatch::Request))

    expect { middleware_raising(exception).call(env) }.to raise_error(exception)
  end

  it 'skips routine 4xx exceptions but still re-raises' do
    exception = ActiveRecord::RecordNotFound.new('missing')

    expect(Axiom::Reporter).not_to receive(:report)
    expect { middleware_raising(exception).call(env) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'reports exceptions that are not StandardError descendants' do
    exception = NotImplementedError.new('nope')

    expect(Axiom::Reporter).to receive(:report)
    expect { middleware_raising(exception).call(env) }.to raise_error(NotImplementedError)
  end
end
