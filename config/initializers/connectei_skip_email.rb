# Connectei — ver modifications/016.
#
# Registra o interceptor que impede envio para os endereços de identidade
# provisionados pelo ERP (marcados com `skipemail`). Fica num initializer
# próprio, sem tocar arquivo do core, para o merge de upstream não conflitar.
require 'connectei/skip_email_interceptor'

ActiveSupport.on_load(:action_mailer) do
  ActionMailer::Base.register_interceptor(Connectei::SkipEmailInterceptor)
end
