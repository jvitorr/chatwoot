require 'rails_helper'

RSpec.describe HelpCenterGeneration do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account_id: account.id) }

  describe 'after_create_commit' do
    it 'enqueues the article generation job' do
      expect do
        account.help_center_generations.create!(portal: portal)
      end.to have_enqueued_job(Onboarding::HelpCenterArticleGenerationJob)
    end
  end
end
