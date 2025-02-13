require 'webmock/rspec'

RSpec.describe TriggerController, :vcr do
  let(:user) { create(:confirmed_user, login: 'foo') }
  let(:project) { create(:project, name: 'project', maintainer: user) }
  let(:package) { create(:package, name: 'package_trigger', project: project) }
  let(:repository) { create(:repository, name: 'package_test_repository', architectures: ['x86_64'], project: project) }

  render_views

  before do
    token_extractor = instance_double(TriggerControllerService::TokenExtractor)
    allow(TriggerControllerService::TokenExtractor).to receive(:new).and_return(token_extractor)
    allow(token_extractor).to receive(:call).and_return(token)
  end

  describe '#rebuild' do
    context 'authentication token is invalid' do
      let(:token) { nil }

      before do
        post :create, params: { format: :xml }
      end

      it { expect(response).to have_http_status(:forbidden) }
      it { expect(response.body).to include('No valid token') }
    end

    context 'when token is valid' do
      let(:token) { Token::Rebuild.create(executor: user, package: package) }

      before do
        allow(Backend::Api::Sources::Package).to receive(:rebuild).and_return("<status code=\"ok\" />\n")

        post :create, params: { format: :xml }
      end

      it { expect(response).to have_http_status(:success) }
    end

    context 'when the token is not bound to a package' do
      context 'without a package passed in the parameters' do
        let(:token) { Token::Rebuild.create(executor: user) }
        let(:expected_response_body) do
          <<~XML
            <status code="bad_request">
              <summary>A package must be provided for the operations rebuild, release and runservice</summary>
            </status>
          XML
        end

        before do
          post :create, params: { format: :xml, project: project }
        end

        it { expect(response).to have_http_status(:bad_request) }
        it { expect(response.body).to include(expected_response_body) }
      end
    end
  end

  describe '#release' do
    let(:target_project) { create(:project, name: 'target_project', maintainer: user) }
    let(:target_repository) { create(:repository, name: 'target_repository', project: target_project, architectures: ['x86_64']) }
    let(:release_target) { create(:release_target, repository: repository, target_repository: target_repository, trigger: 'manual') }

    context 'for inexistent project' do
      let(:token) { Token::Release.create(executor: user, package: package) }

      before do
        post :create, params: { project: 'foo', format: :xml }
      end

      it { expect(response).to have_http_status(:not_found) }
    end

    context 'when token is valid and package exists' do
      let(:token) { Token::Release.create(executor: user, package: package) }

      let(:backend_url) do
        "/build/#{target_project.name}/#{target_repository.name}/x86_64/#{package.name}" \
          "?cmd=copy&oproject=#{CGI.escape(project.name)}&opackage=#{package.name}&orepository=#{repository.name}" \
          '&resign=1&multibuild=1'
      end

      before do
        release_target
        allow(Backend::Connection).to receive(:post).and_call_original
        allow(Backend::Connection).to receive(:post).with(backend_url).and_return("<status code=\"ok\" />\n")
        post :create, params: { package: package, format: :xml }
      end

      it { expect(response).to have_http_status(:success) }
    end

    context 'when user has no rights for source' do
      let(:other_user) { create(:confirmed_user, login: 'mrfluffy') }
      let(:token) { Token::Release.create(executor: other_user, package: package) }

      before do
        release_target
        post :create, params: { package: package, format: :xml }
      end

      it { expect(response).to have_http_status(:forbidden) }
    end

    context 'when user has no rights for target' do
      let(:other_user) { create(:confirmed_user, login: 'mrfluffy') }
      let(:token) { Token::Release.create(executor: other_user, package: package) }
      let!(:relationship_package_user) { create(:relationship_package_user, user: other_user, package: package) }
      let(:expected_response_body) do
        <<~XML
          <status code="trigger_project_not_authorized">
            <summary>You don't have permission to release into project target_project.</summary>
          </status>
        XML
      end

      before do
        release_target
        post :create, params: { package: package, format: :xml }
      end

      it { expect(response).to have_http_status(:forbidden) }
      it { expect(response.body).to include(expected_response_body) }
    end

    context 'when there are no release targets' do
      let(:other_user) { create(:confirmed_user, login: 'mrfluffy') }
      let(:token) { Token::Release.create(executor: other_user, package: package) }
      let!(:relationship_package_user) { create(:relationship_package_user, user: other_user, package: package) }

      before do
        post :create, params: { package: package, format: :xml }
      end

      it { expect(response).to have_http_status(:not_found) }
    end

    context 'when the token is not bound to a package' do
      context 'without a package passed in the parameters' do
        let(:token) { Token::Release.create(executor: user) }
        let(:expected_response_body) do
          <<~XML
            <status code="bad_request">
              <summary>A package must be provided for the operations rebuild, release and runservice</summary>
            </status>
          XML
        end

        before do
          post :create, params: { format: :xml, project: project }
        end

        it { expect(response).to have_http_status(:bad_request) }
        it { expect(response.body).to include(expected_response_body) }
      end
    end
  end

  describe '#runservice' do
    let(:token) { Token::Service.create(executor: user, package: package) }
    let(:package) { create(:package_with_service, name: 'package_with_service', project: project) }

    before do
      post :create, params: { package: package, format: :xml }
    end

    it { expect(response).to have_http_status(:success) }

    context 'when the token is not bound to a package' do
      context 'without a package passed in the parameters' do
        let(:token) { Token::Service.create(executor: user) }
        let(:expected_response_body) do
          <<~XML
            <status code="bad_request">
              <summary>A package must be provided for the operations rebuild, release and runservice</summary>
            </status>
          XML
        end

        before do
          post :create, params: { format: :xml, project: project }
        end

        it { expect(response).to have_http_status(:bad_request) }
        it { expect(response.body).to include(expected_response_body) }
      end
    end

    context 'when the token is of type workflow' do
      let(:token) { create(:workflow_token, executor: user) }
      let(:package) { create(:package_with_service, name: 'package_with_service', project: project) }
      let(:expected_response_body) do
        <<~XML
          <status code="not_found">
            <summary>Token not found</summary>
          </status>
        XML
      end

      before do
        post :create, params: { format: :xml, project: project, package: package }
      end

      it { expect(response).to have_http_status(:not_found) }
      it { expect(response.body).to include(expected_response_body) }
    end
  end

  describe '#create' do
    let(:user) { create(:confirmed_user, :with_home, login: 'tom') }
    let(:service_token) { create(:service_token, executor: user) }
    let(:body) { { hello: :world }.to_json }
    let(:project) { user.home_project }
    let(:package) { create(:package_with_service, name: 'apache2', project: project) }
    let(:token) { Token::Service.create(executor: user, package: package) }
    let(:signature) { 'sha256=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), service_token.string, body) }
    let(:backend_response_ok) { "<status code=\"ok\">\n  <summary>Ok</summary>\n</status>\n" }

    shared_examples 'it verifies the signature' do
      before do
        request.headers[signature_header_name] = signature
      end

      context 'when signature is valid' do
        before do
          allow(Backend::Api::Sources::Package).to receive(:trigger_services).and_return(backend_response_ok)
          post :create, body: body, params: { id: service_token.id, project: project.name, package: package.name, format: :xml }
        end

        it { expect(response).to have_http_status(:success) }
      end

      context 'when token is invalid' do
        let(:token) { nil }

        it 'renders an error with an invalid signature' do
          request.headers[signature_header_name] = 'sha256=invalid'
          post :create, body: body, params: { project: project.name, package: package.name, format: :xml }
          expect(response).to have_http_status(:forbidden)
        end

        it 'renders an error with an invalid token' do
          post :create, body: body, params: { project: project.name, package: package.name, format: :xml }
          expect(response).to have_http_status(:forbidden)
        end
      end
    end

    context 'with HTTP_X_OBS_SIGNATURE http header' do
      let(:signature_header_name) { 'HTTP_X_OBS_SIGNATURE' }

      it_behaves_like 'it verifies the signature'
    end

    context 'with HTTP_X_HUB_SIGNATURE_256 http header' do
      let(:signature_header_name) { 'HTTP_X_HUB_SIGNATURE_256' }

      it_behaves_like 'it verifies the signature'
    end

    context 'with HTTP_X-Pagure-Signature-256 http header' do
      let(:signature_header_name) { 'HTTP_X-Pagure-Signature-256' }

      it_behaves_like 'it verifies the signature'
    end

    context 'when some parameters are not strings' do
      before do
        request.headers['ACCEPT'] = '*/*'
        request.headers['CONTENT_TYPE'] = 'application/json'
        request.headers['HTTP_X_OBS_SIGNATURE'] = signature
        allow(Backend::Api::Sources::Package).to receive(:trigger_services).and_return(backend_response_ok)
        post :create, body: { a_hash: { integer1: 123 }, integer2: 456 }.to_json
      end

      it 'still processes the request without validating parameters' do
        expect(response).to have_http_status(:success)
      end
    end
  end
end
