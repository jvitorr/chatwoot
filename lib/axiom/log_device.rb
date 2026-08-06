###############
# Logger device that buffers structured log events and ships them to Axiom in batches.
#
# #write must never block: it runs on request and job threads, so an HTTP call there
# would put Axiom's latency (and outages) directly in the request path. All delivery
# happens on the background thread; #write only appends and signals it.
############

class Axiom::LogDevice
  BUFFER_LIMIT = 100
  FLUSH_INTERVAL = 5
  # Hard cap so an Axiom outage cannot grow the buffer without bound. Oldest events
  # are dropped first, silently: reporting the drop through Rails.logger would feed
  # straight back into this device.
  MAX_BUFFER = 10_000

  def initialize(buffer_limit: BUFFER_LIMIT, flush_interval: FLUSH_INTERVAL, max_buffer: MAX_BUFFER)
    @buffer_limit = buffer_limit
    @flush_interval = flush_interval
    @max_buffer = max_buffer
    @buffer = []
    @mutex = Mutex.new
    @ready = ConditionVariable.new
    start_flush_thread
    at_exit { flush }
  end

  def write(event)
    # Delivery failures log a warning, which lands back here when this device is
    # broadcast onto Rails.logger. Ignore anything emitted while we are delivering.
    return if Thread.current[:axiom_delivering]
    # [FORK CONNECTEI] modifications/008: descarta ruido de scanners antes do
    # buffer (sem I/O — respeita a invariante de nunca bloquear no #write).
    return if Axiom::LogNoiseFilter.noise?(event)

    @mutex.synchronize do
      @buffer << event
      @buffer.shift(@buffer.length - @max_buffer) if @buffer.length > @max_buffer
      @ready.signal if @buffer.length >= @buffer_limit
    end
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

    Thread.current[:axiom_delivering] = true
    Axiom::IngestClient.push(batch)
  ensure
    Thread.current[:axiom_delivering] = nil
  end

  # Wakes on the interval or as soon as #write signals a full buffer, whichever
  # comes first, so a burst is not held back for the whole interval.
  def start_flush_thread
    Thread.new do
      loop do
        @mutex.synchronize { @ready.wait(@mutex, @flush_interval) }
        flush
      end
    end
  end
end
