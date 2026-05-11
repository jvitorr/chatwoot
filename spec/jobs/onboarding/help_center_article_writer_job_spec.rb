require 'rails_helper'

RSpec.describe Onboarding::HelpCenterArticleWriterJob do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account_id: account.id) }
  let(:plan) do
    { 'articles' => [
      { 'urls' => ['https://x.test/a'], 'title' => 'A', 'category_id' => nil },
      { 'urls' => ['https://x.test/b'], 'title' => 'B', 'category_id' => nil }
    ] }
  end
  let(:generation) do
    HelpCenterGeneration.create!(account: account, portal: portal, status: :generating, plan: plan)
  end

  before { clear_enqueued_jobs }

  describe 'queue' do
    it 'enqueues on the low queue' do
      expect { described_class.perform_later(generation, 0) }
        .to have_enqueued_job(described_class).on_queue('low')
    end
  end

  describe 'success path' do
    before do
      builder = instance_double(Onboarding::HelpCenterArticleBuilder, perform: true)
      allow(Onboarding::HelpCenterArticleBuilder).to receive(:new).and_return(builder)
    end

    it 'invokes the builder and increments articles_finished' do
      expect { described_class.perform_now(generation, 0) }
        .to change { generation.reload.articles_finished }.by(1)
    end

    it 'transitions to completed once the last writer finishes' do
      described_class.perform_now(generation, 0)
      expect(generation.reload.status).to eq('generating')

      described_class.perform_now(generation, 1)
      expect(generation.reload).to be_completed
      expect(generation.finished_at).to be_present
    end
  end

  describe 'failure handling' do
    it 'increments the counter on ArticleBuildFailed without re-raising' do
      allow(Onboarding::HelpCenterArticleBuilder).to receive(:new).and_raise(
        CustomExceptions::HelpCenter::ArticleBuildFailed, 'no source urls'
      )
      expect { described_class.perform_now(generation, 0) }
        .to change { generation.reload.articles_finished }.by(1)
    end

    it 're-enqueues itself on transient Firecrawl errors' do
      allow(Onboarding::HelpCenterArticleBuilder).to receive(:new).and_raise(
        Firecrawl::FirecrawlError, 'transient'
      )
      expect { described_class.perform_now(generation, 0) }
        .to have_enqueued_job(described_class).with(generation, 0)
    end

    it 'increments the counter when Firecrawl retries are exhausted' do
      allow(Onboarding::HelpCenterArticleBuilder).to receive(:new).and_raise(
        Firecrawl::FirecrawlError, 'always failing'
      )
      perform_enqueued_jobs do
        described_class.perform_later(generation, 0)
      end
      expect(generation.reload.articles_finished).to eq(1)
    end
  end
end
