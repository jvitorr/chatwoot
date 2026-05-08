class Public::Api::V1::Portals::CategoriesController < Public::Api::V1::Portals::BaseController
  before_action :ensure_custom_domain_request, only: [:show, :index]
  before_action :portal
  before_action :ensure_portal_feature_enabled
  before_action :set_category, only: [:show]
  layout 'portal'

  def index
    locale = params[:locale].presence || @portal.default_locale
    target = helpers.append_design_query("/hc/#{@portal.slug}/#{locale}", @design_query_param)
    redirect_to target, status: :moved_permanently
  end

  def show
    @og_image_url = helpers.set_og_image_url(@portal.name, @category.name)
    render template: 'public/api/v1/portals/sidebar/categories/show' if @design_version == 'sidebar'
  end

  private

  def set_category
    @category = @portal.categories.find_by(locale: params[:locale], slug: params[:category_slug])

    Rails.logger.info "Category: not found for slug: #{params[:category_slug]}"
    render_404 && return if @category.blank?
  end
end
