require 'rails_helper'

# O ERP provisiona cada atendente com um e-mail sintético marcado com
# `skipemail`. Ele é chave de identidade, não caixa postal: entregar ali gera
# bounce em série, que suja a reputação do domínio e acaba atingindo as
# mensagens que importam — as que vão para o cliente final.
describe Connectei::SkipEmailInterceptor do
  let(:mailer) { ActionMailer::Base }

  # rubocop:disable Rails/I18nLocaleTexts -- assunto de fixture, não vai para UI
  def build_message(to:, cc: nil, bcc: nil)
    mailer.mail(to: to, cc: cc, bcc: bcc, subject: 'Conversa atribuida', body: 'corpo')
  end
  # rubocop:enable Rails/I18nLocaleTexts

  def intercept(message)
    described_class.delivering_email(message)
    message
  end

  it 'cancela a entrega quando o único destinatário é de identidade do ERP' do
    message = intercept(build_message(to: 'store_87_147_skipemail@connectei.com'))

    expect(message.perform_deliveries).to be(false)
  end

  it 'não interfere em e-mail legítimo' do
    message = intercept(build_message(to: 'cliente@exemplo.com'))

    expect(message.perform_deliveries).to be(true)
    expect(message.to).to eq(['cliente@exemplo.com'])
  end

  # O que protege o cliente final: uma mensagem com destinatário real E um
  # sintético não pode ser cancelada inteira — o cliente perderia o e-mail.
  it 'remove só o destinatário de identidade e entrega para o resto' do
    message = intercept(
      build_message(to: ['cliente@exemplo.com', 'store_87_147_skipemail@connectei.com'])
    )

    expect(message.perform_deliveries).to be(true)
    expect(message.to).to eq(['cliente@exemplo.com'])
  end

  it 'limpa também cópia e cópia oculta' do
    message = intercept(
      build_message(
        to: 'cliente@exemplo.com',
        cc: 'store_1_2_skipemail@connectei.com',
        bcc: ['store_1_3_skipemail@connectei.com', 'gestor@exemplo.com']
      )
    )

    expect(message.cc).to be_nil
    expect(message.bcc).to eq(['gestor@exemplo.com'])
    expect(message.perform_deliveries).to be(true)
  end

  it 'reconhece o marcador em qualquer caixa (o endereço pode vir normalizado)' do
    message = intercept(build_message(to: 'STORE_87_147_SKIPEMAIL@connectei.com'))

    expect(message.perform_deliveries).to be(false)
  end

  it 'não confunde endereço legítimo que apenas contenha palavras parecidas' do
    message = intercept(build_message(to: 'skip.email@exemplo.com'))

    expect(message.perform_deliveries).to be(true)
  end
end
