require 'rails_helper'

# [FORK CONNECTEI] modifications/025
describe Connectei::Instagram::GraphError do
  describe '.details' do
    it 'reads code, subcode and message from a parsed Graph error' do
      parsed = { 'error' => { 'code' => 10, 'error_subcode' => 2_534_022, 'message' => 'outside window' } }

      expect(described_class.details(parsed)).to eq(code: 10, subcode: 2_534_022, message: 'outside window')
    end

    it 'accepts a raw JSON string and numeric strings' do
      raw = { error: { code: '613', error_subcode: nil, message: 'Calls exceeded' } }.to_json

      expect(described_class.details(raw)).to eq(code: 613, subcode: nil, message: 'Calls exceeded')
    end

    it 'returns nils for a body that is not a Graph error' do
      expect(described_class.details('<html>502</html>')).to eq(code: nil, subcode: nil, message: nil)
      expect(described_class.details(nil)).to eq(code: nil, subcode: nil, message: nil)
    end
  end

  describe '.message_kind (contract §4)' do
    {
      [190, nil] => 'token',
      [4, nil] => 'rate_limited', [17, nil] => 'rate_limited', [32, nil] => 'rate_limited',
      [613, nil] => 'rate_limited', [80_002, nil] => 'rate_limited',
      [10, 2_534_022] => 'window_closed',
      [551, 1_545_041] => 'user_unavailable', [100, 2_534_014] => 'user_unavailable',
      [100, nil] => 'unknown', [1, nil] => 'unknown', [nil, nil] => 'unknown'
    }.each do |(code, subcode), kind|
      it "maps #{code.inspect}/#{subcode.inspect} to #{kind} for a regular message" do
        expect(described_class.message_kind(code, subcode)).to eq(kind)
      end
    end

    {
      [100, nil] => 'comment_unavailable', [33, nil] => 'comment_unavailable', [10, 2_534_022] => 'comment_unavailable',
      [551, nil] => 'user_unavailable', [190, nil] => 'token', [613, nil] => 'rate_limited', [10, nil] => 'unknown'
    }.each do |(code, subcode), kind|
      it "maps #{code.inspect}/#{subcode.inspect} to #{kind} for a private reply" do
        expect(described_class.message_kind(code, subcode, private_reply: true)).to eq(kind)
      end
    end

    it 'only produces the kinds listed in the contract' do
      [[190, nil], [4, nil], [10, 2_534_022], [551, nil], [100, nil], [nil, nil]].each do |code, subcode|
        expect(described_class::MESSAGE_KINDS).to include(described_class.message_kind(code, subcode))
        expect(described_class::MESSAGE_KINDS).to include(described_class.message_kind(code, subcode, private_reply: true))
      end
    end
  end

  describe '.endpoint_error (contract §2.1)' do
    {
      [613, 400] => [:rate_limited, 429], [80_002, 400] => [:rate_limited, 429], [4, 429] => [:rate_limited, 429],
      [190, 400] => [:reauthorization_required, 403],
      [230, 400] => [:consent_required, 409],
      [100, 400] => [:not_found, 404], [33, 400] => [:not_found, 404],
      [10, 403] => [:permission_denied, 403], [200, 403] => [:permission_denied, 403],
      [2, 503] => [:unavailable, 503], [nil, 500] => [:unavailable, 503],
      [9999, 400] => [:invalid, 422], [nil, 400] => [:invalid, 422]
    }.each do |(code, status), expected|
      it "maps Graph code #{code.inspect} (HTTP #{status}) to #{expected.inspect}" do
        expect(described_class.endpoint_error(code, status)).to eq(expected)
      end
    end
  end
end
