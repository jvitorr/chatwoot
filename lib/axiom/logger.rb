###############
# Builds the secondary logger broadcast to Axiom.
# The formatter emits a Hash instead of a String so events land structured in the dataset.
############

class Axiom::Logger
  class << self
    def build
      logger = ActiveSupport::Logger.new(Axiom::LogDevice.new)
      logger.level = ::Logger.const_get(Axiom.log_level.upcase)
      logger.formatter = proc do |severity, timestamp, progname, message|
        {
          _time: timestamp.iso8601,
          level: severity.to_s.downcase,
          progname: progname,
          message: normalize(message)
        }.compact
      end
      logger
    end

    def normalize(message)
      case message
      when String then message
      when Exception then "#{message.message} (#{message.class})"
      else message.inspect
      end
    end
  end
end
