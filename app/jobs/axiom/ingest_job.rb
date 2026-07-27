class Axiom::IngestJob < ApplicationJob
  queue_as :low

  def perform(events)
    Axiom::IngestClient.push(events)
  end
end
