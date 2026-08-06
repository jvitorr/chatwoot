require 'rails_helper'

# [FORK CONNECTEI] modifications/008-filtro-ruido-scanners-axiom.md
describe Axiom::LogNoiseFilter do
  describe '.noise?' do
    it 'matches RoutingError log lines from scanners' do
      event = {
        _time: '2026-08-06T00:00:00Z',
        level: 'fatal',
        message: "ActionController::RoutingError (No route matches [GET] \"/wp-includes/Text\"):\n\nlib/middleware..."
      }

      expect(described_class.noise?(event)).to be true
    end

    it 'matches when the event uses string keys' do
      event = { 'message' => 'ActionController::RoutingError (No route matches [GET] "/about.php"):' }

      expect(described_class.noise?(event)).to be true
    end

    it 'does not match ordinary fatal events' do
      event = { level: 'fatal', message: 'PG::InFailedSqlTransaction: ERROR: current transaction is aborted' }

      expect(described_class.noise?(event)).to be false
    end

    it 'does not match a RoutingError merely mentioned mid-sentence by application code' do
      event = { message: 'retrying after ActionController::RoutingError-like failure' }

      expect(described_class.noise?(event)).to be false
    end

    it 'handles non-hash events' do
      expect(described_class.noise?('plain string log')).to be false
      expect(described_class.noise?(nil)).to be false
    end
  end
end
