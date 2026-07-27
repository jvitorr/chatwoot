require 'rails_helper'

describe Axiom::ExceptionEvent do
  let(:exception) do
    StandardError.new('boom').tap do |e|
      app_frame = Rails.root.join('app/services/foo_service.rb').to_s
      e.set_backtrace(["#{app_frame}:12:in `call'", "/gems/rack/lib/rack.rb:3:in `run'"])
    end
  end

  it 'builds the base payload' do
    event = described_class.new(exception).to_h

    expect(event[:level]).to eq 'error'
    expect(event[:message]).to eq 'boom'
    expect(event[:exception_class]).to eq 'StandardError'
  end

  it 'parses the backtrace into frames with app-relative paths' do
    frames = described_class.new(exception).to_h[:stacktrace]

    expect(frames.first).to eq(file: 'app/services/foo_service.rb', line: 12, method: 'call')
    expect(frames.second[:file]).to eq '/gems/rack/lib/rack.rb'
  end

  it 'gives the same fingerprint to the same defect and a different one otherwise' do
    same = described_class.new(exception).to_h[:fingerprint]
    other = described_class.new(ArgumentError.new('boom').tap { |e| e.set_backtrace(exception.backtrace) }).to_h[:fingerprint]

    expect(described_class.new(exception).to_h[:fingerprint]).to eq same
    expect(other).not_to eq same
  end

  it 'handles an exception without a backtrace' do
    event = described_class.new(StandardError.new('bare')).to_h

    expect(event[:message]).to eq 'bare'
    expect(event).not_to have_key(:stacktrace)
  end

  context 'with account and user' do
    let(:account) { create(:account) }
    let(:user) { create(:user) }

    it 'adds both contexts' do
      event = described_class.new(exception, user: user, account: account).to_h

      expect(event[:account_id]).to eq account.id
      expect(event[:user_email]).to eq user.email
    end

    it 'ignores a user that is not a User' do
      expect(described_class.new(exception, user: 'nope').to_h).not_to have_key(:user_id)
    end
  end

  context 'with a request' do
    let(:request) do
      # Rails injects the parameter filter into the env at request time; mirror that here.
      env = Rack::MockRequest.env_for('/orders?password=secret&q=shoes', 'REMOTE_ADDR' => '1.2.3.4', 'HTTP_USER_AGENT' => 'curl')
      env['action_dispatch.parameter_filter'] = Rails.application.config.filter_parameters
      ActionDispatch::Request.new(env)
    end

    it 'adds request context and filters sensitive params' do
      event = described_class.new(exception, request: request).to_h

      expect(event[:request_method]).to eq 'GET'
      expect(event[:remote_ip]).to eq '1.2.3.4'
      expect(event[:user_agent]).to eq 'curl'
      expect(event[:params]['q']).to eq 'shoes'
      expect(event[:params]['password']).to eq '[FILTERED]'
      expect(event[:url]).not_to include 'secret'
    end
  end

  context 'with sidekiq context' do
    it 'adds job details' do
      context = { job: { 'class' => 'SomeJob', 'queue' => 'low', 'retry_count' => 2 } }
      event = described_class.new(exception, context: context).to_h

      expect(event[:job_class]).to eq 'SomeJob'
      expect(event[:job_queue]).to eq 'low'
      expect(event[:job_retry_count]).to eq 2
    end

    it 'prefers the wrapped ActiveJob class' do
      context = { job: { 'class' => 'Sidekiq::ActiveJob::Wrapper', 'wrapped' => 'RealJob' } }

      expect(described_class.new(exception, context: context).to_h[:job_class]).to eq 'RealJob'
    end
  end
end
