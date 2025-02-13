class TriggerController < ApplicationController
  include Triggerable
  include Trigger::Errors

  # Authentication happens with tokens, so extracting the user is not required
  skip_before_action :extract_user
  # Authentication happens with tokens, so no login is required
  skip_before_action :require_login
  # SCMs like GitLab/GitHub send data as parameters which are not strings (e.g.: GitHub - PR number is a integer, GitLab - project is a hash)
  # Other SCMs might also do this, so we're not validating parameters.
  skip_before_action :validate_params

  before_action :set_token
  before_action :check_token_class
  before_action :set_project_name
  before_action :set_package_name
  # From Triggerable
  before_action :set_project
  before_action :set_package
  before_action :set_object_to_authorize
  # set_multibuild_flavor needs to run after the set_object_to_authorize callback
  append_before_action :set_multibuild_flavor

  after_action :verify_authorized

  def create
    authorize @token, :trigger?

    @token.executor.run_as do
      opts = { project: @project, package: @package, repository: params[:repository], arch: params[:arch],
               targetproject: params[:targetproject], targetrepository: params[:targetrepository],
               filter_source_repository: params[:filter_source_repository] }
      opts[:multibuild_flavor] = @multibuild_container if @multibuild_container.present?
      @token.call(opts)
      render_ok
    end
  rescue ArgumentError => e
    render_error status: 400, message: e
  end

  private

  def check_token_class
    # It make no sense to process Token::Workflows on a runservice request
    raise ActiveRecord::RecordNotFound, 'Token not found' if @token.instance_of?(Token::Workflow)
  end

  # AUTHENTICATION
  def set_token
    @token = ::TriggerControllerService::TokenExtractor.new(request).call
    raise InvalidToken, 'No valid token found' unless @token
  end

  def pundit_user
    @token.executor
  end

  def set_project_name
    @project_name = params[:project]
  end

  def set_package_name
    @package_name = params[:package]
    raise MissingPackage if @package_name.blank? && @token.package_id.nil? && @token.token_name.in?(['rebuild', 'release', 'service'])
  end
end
