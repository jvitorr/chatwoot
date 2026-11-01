# [FORK CONNECTEI] modifications/030-deploy-4.15.1.13.md
namespace :connectei do
  namespace :instagram do
    desc 'Reinscreve os canais Instagram no webhook com os campos atuais (mod 024). DRY_RUN=1 só lista; CHANNEL_IDS=1,2 filtra.'
    task resubscribe: :environment do
      channel_ids = ENV.fetch('CHANNEL_IDS', '').split(',').map(&:strip).compact_blank
      dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch('DRY_RUN', 'false'))

      Connectei::Instagram::Resubscriber.new(dry_run: dry_run, channel_ids: channel_ids).perform
    end
  end
end
