class Whatsapp::MediaServerClient
  class ConnectionError < StandardError; end
  class SessionError < StandardError; end

  TIMEOUT = 10

  def create_session(call_id:, sdp_offer:, ice_servers:, account_id: nil)
    body = { call_id: call_id, meta_sdp_offer: sdp_offer, ice_servers: ice_servers, account_id: account_id }.compact
    post('/sessions', body)
  end

  def generate_agent_offer(session_id)
    post("/sessions/#{session_id}/agent-offer")
  end

  def set_agent_answer(session_id, sdp_answer:)
    post("/sessions/#{session_id}/agent-answer", { sdp_answer: sdp_answer })
  end

  def reconnect_agent(session_id)
    post("/sessions/#{session_id}/agent-reconnect")
  end

  def terminate_session(session_id)
    post("/sessions/#{session_id}/terminate")
  end

  def download_recording(session_id)
    response = execute_request(:get, "/sessions/#{session_id}/recording")
    unless response.success?
      Rails.logger.error "[MEDIA SERVER] Recording download failed: status=#{response.code}"
      raise SessionError, "Recording download failed (#{response.code})"
    end
    response.body
  end

  def add_peer(session_id, role:, label:)
    post("/sessions/#{session_id}/peers", { role: role, label: label })
  end

  def remove_peer(session_id, peer_id:)
    delete("/sessions/#{session_id}/peers/#{peer_id}")
  end

  def inject_audio(session_id, file_path:, mode: 'replace', loop: false, target: 'peer_a')
    post("/sessions/#{session_id}/inject-audio", { file_path: file_path, mode: mode, loop: loop, target: target })
  end

  def stop_audio_injection(session_id, injection_id:)
    delete("/sessions/#{session_id}/inject-audio/#{injection_id}")
  end

  def health_check
    get('/health')
  end

  private

  def post(path, body = {})
    response = execute_request(:post, path, body)
    parse_response(response)
  end

  def get(path)
    response = execute_request(:get, path)
    parse_response(response)
  end

  def delete(path)
    response = execute_request(:delete, path)
    parse_response(response)
  end

  def execute_request(method, path, body = nil)
    url = "#{base_url}#{path}"
    options = { headers: auth_headers, timeout: TIMEOUT }
    options[:body] = body.to_json if body.present?

    Rails.logger.info "[MEDIA SERVER] #{method.upcase} #{path}"
    HTTParty.send(method, url, options)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    Rails.logger.error "[MEDIA SERVER] Connection failed: #{e.class} #{e.message}"
    raise ConnectionError, "Media server unavailable: #{e.message}"
  end

  def parse_response(response)
    unless response.success?
      Rails.logger.error "[MEDIA SERVER] Request failed: status=#{response.code} body=#{response.body}"
      raise SessionError, "Media server error (#{response.code}): #{response.body}"
    end

    response.parsed_response
  end

  def base_url
    ENV.fetch('MEDIA_SERVER_URL', 'http://localhost:4000')
  end

  def auth_token
    ENV.fetch('MEDIA_SERVER_AUTH_TOKEN', '')
  end

  def auth_headers
    {
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{auth_token}"
    }
  end
end
