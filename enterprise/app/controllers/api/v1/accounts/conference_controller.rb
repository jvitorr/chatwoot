class Api::V1::Accounts::ConferenceController < Api::V1::Accounts::BaseController
  before_action :set_voice_inbox_for_conference

  def token
    render json: Voice::Provider::Twilio::TokenService.new(
      inbox: @voice_inbox,
      user: Current.user,
      account: Current.account
    ).generate
  end

  def create
    conversation = fetch_conversation_by_display_id
    call = find_or_initialize_call!(conversation)

    conference_service = Voice::Provider::Twilio::ConferenceService.new(call: call)
    conference_sid = conference_service.ensure_conference_sid
    conference_service.mark_agent_joined(user: current_user)

    render json: {
      status: 'success',
      id: conversation.display_id,
      conference_sid: conference_sid,
      using_webrtc: true
    }
  end

  def destroy
    conversation = fetch_conversation_by_display_id
    call = Current.account.calls.where(conversation_id: conversation.id).order(created_at: :desc).first
    return render(json: { status: 'success', id: conversation.display_id }) unless call

    Voice::Provider::Twilio::ConferenceService.new(call: call).end_conference
    render json: { status: 'success', id: conversation.display_id }
  end

  private

  def find_or_initialize_call!(conversation)
    sid = params[:call_sid].presence
    existing = Current.account.calls.where(conversation_id: conversation.id, provider: :twilio)
    existing = existing.where(provider_call_id: sid) if sid
    call = existing.order(created_at: :desc).first
    return call if call

    raise ActionController::ParameterMissing, :call_sid unless sid

    Current.account.calls.create!(
      inbox_id: conversation.inbox_id,
      conversation: conversation,
      contact_id: conversation.contact_id,
      provider: :twilio,
      direction: :outgoing,
      status: 'ringing',
      provider_call_id: sid,
      accepted_by_agent_id: current_user.id
    )
  end

  def set_voice_inbox_for_conference
    @voice_inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @voice_inbox, :show?
  end

  def fetch_conversation_by_display_id
    cid = params[:conversation_id]
    raise ActiveRecord::RecordNotFound, 'conversation_id required' if cid.blank?

    conversation = @voice_inbox.conversations.find_by!(display_id: cid)
    authorize conversation, :show?
    conversation
  end
end
