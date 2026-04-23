require 'ssrf_filter'

module SafeFetch
  DEFAULT_ALLOWED_CONTENT_TYPE_PREFIXES = %w[image/ video/ audio/].freeze
  DEFAULT_ALLOWED_CONTENT_TYPES = %w[
    text/csv
    text/plain
    text/rtf
    application/json
    application/pdf
    application/zip
    application/x-7z-compressed
    application/vnd.rar
    application/x-tar
    application/msword
    application/vnd.ms-excel
    application/vnd.ms-powerpoint
    application/rtf
    application/vnd.oasis.opendocument.text
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
  ].freeze
  DEFAULT_SENSITIVE_HEADERS = %w[authorization cookie].freeze
  DEFAULT_OPEN_TIMEOUT = 2
  DEFAULT_READ_TIMEOUT = 20
  DEFAULT_MAX_BYTES_FALLBACK_MB = 40

  Result = Data.define(:tempfile, :filename, :content_type) do
    def original_filename
      filename
    end

    def close!
      tempfile.close! if tempfile.respond_to?(:close!)
    end
  end

  class Error < StandardError; end
  class InvalidUrlError < Error; end
  class UnsafeUrlError < Error; end
  class FetchError < Error; end
  class HttpError < Error; end
  class FileTooLargeError < Error; end
  class UnsupportedContentTypeError < Error; end
  class UnsupportedMethodError < Error; end
end

require_relative 'safe_fetch/request_options'
require_relative 'safe_fetch/fetcher'

module SafeFetch
  def self.fetch(url, **, &)
    raise ArgumentError, 'block required' unless block_given?

    Fetcher.new(RequestOptions.new(url: url, **)).fetch(&)
  rescue SsrfFilter::InvalidUriScheme, URI::InvalidURIError => e
    raise InvalidUrlError, e.message
  rescue SsrfFilter::Error, Resolv::ResolvError => e
    raise UnsafeUrlError, e.message
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError => e
    raise FetchError, e.message
  end
end
