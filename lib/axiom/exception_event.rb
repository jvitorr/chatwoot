###############
# Builds the structured payload for an exception sent to Axiom.
# Frames are parsed out of the backtrace so the dataset can be queried by file/method,
# and the fingerprint gives Axiom a stable key to group repeated occurrences by.
############

class Axiom::ExceptionEvent
  FRAME_LIMIT = 20
  FRAME_PATTERN = /\A(?<file>.*?):(?<line>\d+)(?::in [`'](?<method>.*)')?/

  def initialize(exception, user: nil, account: nil, request: nil, context: nil)
    @exception = exception
    @user = user
    @account = account
    @request = request
    @context = context
  end

  def to_h
    base.merge(account_context).merge(user_context).merge(request_context).merge(job_context).compact
  end

  private

  def base
    {
      level: 'error',
      message: @exception.try(:message) || @exception.to_s,
      exception_class: @exception.class.name,
      backtrace: backtrace,
      stacktrace: frames,
      fingerprint: fingerprint
    }
  end

  def backtrace
    @backtrace ||= @exception.try(:backtrace)&.first(FRAME_LIMIT)
  end

  def frames
    backtrace&.filter_map do |line|
      match = FRAME_PATTERN.match(line)
      next if match.blank?

      { file: relative_path(match[:file]), line: match[:line].to_i, method: match[:method] }.compact
    end
  end

  # Only app paths become relative; gem paths keep their leading slash, which is what
  # fingerprint uses to tell an app frame from a dependency frame.
  def relative_path(file)
    file.delete_prefix("#{Rails.root}/") # rubocop:disable Rails/FilePath
  end

  # Group by the exception class plus the first frame inside the app, so the same
  # defect reported from different requests collapses into one bucket.
  def fingerprint
    app_frame = frames&.find { |frame| !frame[:file].start_with?('/') }
    Digest::SHA256.hexdigest("#{@exception.class.name}:#{app_frame&.values_at(:file, :method)&.join(':')}")[0, 16]
  end

  def account_context
    return {} if @account.blank?

    { account_id: @account.id, account_name: @account.name }
  end

  def user_context
    return {} unless @user.is_a?(User)

    { user_id: @user.id, user_email: @user.email }
  end

  def request_context
    return {} if @request.blank?

    {
      request_id: @request.request_id,
      request_method: @request.request_method,
      url: @request.filtered_path,
      remote_ip: @request.remote_ip,
      user_agent: @request.user_agent,
      params: filtered_params
    }
  end

  # Reuses the app's filter_parameters so passwords and tokens never reach the dataset.
  def filtered_params
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filter.filter(@request.filtered_parameters.except('controller', 'action', 'format'))
  rescue StandardError
    nil
  end

  def job_context
    return {} if @context.blank?

    job = @context[:job] || {}
    { job_class: job['wrapped'] || job['class'], job_queue: job['queue'], job_retry_count: job['retry_count'] }
  end
end
