###############
# Logger device that buffers structured log events and ships them to Axiom in batches.
# Batching is what keeps this from issuing one HTTP request per log line.
############

class Axiom::LogDevice
  BUFFER_LIMIT = 100
  FLUSH_INTERVAL = 5

  def initialize(buffer_limit: BUFFER_LIMIT, flush_interval: FLUSH_INTERVAL)
    @buffer_limit = buffer_limit
    @flush_interval = flush_interval
    @buffer = []
    @mutex = Mutex.new
    start_flush_thread
    at_exit { flush }
  end

  def write(event)
    batch = @mutex.synchronize do
      @buffer << event
      @buffer.slice!(0, @buffer.length) if @buffer.length >= @buffer_limit
    end
    deliver(batch)
  end

  def flush
    deliver(@mutex.synchronize { @buffer.slice!(0, @buffer.length) })
  end

  def close
    flush
  end

  private

  def deliver(batch)
    return if batch.blank?

    Axiom::IngestClient.push(batch)
  end

  def start_flush_thread
    Thread.new do
      loop do
        sleep @flush_interval
        flush
      end
    end
  end
end
