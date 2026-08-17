# Analytics de leads do painel do ERP Connectei — ver modifications/019.
#
# Aditivo: não altera nenhum endpoint/serviço existente. Contrato público
# (validação de intervalo, formato de erro, permissão) é responsabilidade do
# ERP — este endpoint só serve o ERP e valida o mínimo para não deixar uma
# chamada malformada virar 500 do Postgres.
class Api::V1::Accounts::ConnecteiLeadAnalyticsController < Api::V1::Accounts::BaseController
  before_action :validate_inbox_ids!
  before_action :validate_dates!
  before_action :validate_granularity!

  def filter
    result = Connectei::LeadAnalyticsQuery.new(
      account: Current.account,
      params: permitted_params
    ).perform

    render json: result
  end

  private

  def validate_inbox_ids!
    requested = Array(params[:inbox_ids]).flat_map { |id| id.to_s.split(',') }.map(&:strip).reject(&:empty?).map(&:to_i).uniq
    return if requested.blank?

    unknown = requested - Current.account.inboxes.where(id: requested).pluck(:id)
    return if unknown.blank?

    render json: { error: "inbox_ids not found in this account: #{unknown.join(',')}" }, status: :unprocessable_entity
  end

  def validate_dates!
    error = date_range_error
    return if error.nil?

    render json: { error: error }, status: :unprocessable_entity
  end

  def date_range_error
    format_error = date_format_error(:start_at) || date_format_error(:end_at)
    return format_error if format_error

    start_at = parse_time(params[:start_at])
    end_at = parse_time(params[:end_at])
    return 'start_at and end_at are required' if start_at.blank? || end_at.blank?
    return 'start_at must be before or equal to end_at' if start_at > end_at

    nil
  end

  def date_format_error(field)
    return nil if params[field].blank?
    return nil if parse_time(params[field])

    "#{field} must be a valid ISO 8601 datetime"
  end

  def validate_granularity!
    return if params[:granularity].blank?
    return if Connectei::LeadAnalyticsQuery::GRANULARITIES.include?(params[:granularity].to_s)

    render json: { error: "granularity must be one of #{Connectei::LeadAnalyticsQuery::GRANULARITIES.join(', ')}" }, status: :unprocessable_entity
  end

  def parse_time(value)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def permitted_params
    params.permit(:start_at, :end_at, :granularity, :timezone, inbox_ids: [])
  end
end
