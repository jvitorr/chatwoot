require 'ipaddr'
require 'resolv'
require 'ssrf_filter'
require 'uri'

module SafeOutboundUrl
  class Error < StandardError; end
  class InvalidUrlError < Error; end
  class UnsafeUrlError < Error; end

  def self.validate!(url, resolver: SsrfFilter::DEFAULT_RESOLVER)
    uri = parse_http_url!(url)
    ip_addresses = resolve_addresses(uri.hostname, resolver)

    raise UnsafeUrlError, "Could not resolve hostname '#{uri.hostname}'" if ip_addresses.empty?
    raise UnsafeUrlError, "Hostname '#{uri.hostname}' has no public ip addresses" if ip_addresses.all? { |ip| unsafe_ip_address?(ip) }

    uri
  rescue URI::InvalidURIError => e
    raise InvalidUrlError, e.message
  rescue IPAddr::InvalidAddressError, Resolv::ResolvError => e
    raise UnsafeUrlError, e.message
  end

  def self.parse_http_url!(url)
    uri = URI.parse(url.to_s)
    raise InvalidUrlError, 'scheme must be http or https' unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    raise InvalidUrlError, 'missing host' if uri.hostname.blank?

    uri
  end
  private_class_method :parse_http_url!

  def self.resolve_addresses(hostname, resolver)
    Array(resolver.call(hostname)).map { |ip| ip.is_a?(IPAddr) ? ip : IPAddr.new(ip) }
  end
  private_class_method :resolve_addresses

  def self.unsafe_ip_address?(ip_address)
    SsrfFilter.send(:unsafe_ip_address?, ip_address)
  end
  private_class_method :unsafe_ip_address?
end
