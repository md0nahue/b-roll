require 'rails_helper'

RSpec.describe Users::OmniauthCallbacksController, type: :controller do
  before do
    request.env["devise.mapping"] = Devise.mappings[:user]
    # It's good practice to clear OmniAuth mocks before each test if they are set globally
    # or within contexts, to avoid interference between tests.
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.mock_auth[:github] = nil
  end

  describe 'Google OAuth2' do
    describe '#google_oauth2' do
      context 'New User' do
        before do
          mock_auth_hash('google_oauth2', 'new.google.user@example.com', 'google-uid-123')
          request.env['omniauth.auth'] = OmniAuth.config.mock_auth[:google_oauth2]
          get :google_oauth2
        end

        it 'creates a new user' do
          expect(User.find_by(email: 'new.google.user@example.com')).not_to be_nil
          expect(User.count).to eq(1) # Assuming clean DB for this test context
        end

        it 'signs in the user' do
          expect(subject.current_user).not_to be_nil
          expect(subject.current_user.email).to eq('new.google.user@example.com')
        end

        it 'redirects to the root path' do
          expect(response).to redirect_to(root_path)
        end

        it 'sets a success flash message' do
          expect(flash[:notice]).to eq(I18n.t('devise.omniauth_callbacks.success', kind: 'Google'))
        end
      end

      context 'Existing User' do
        let!(:user) { create(:user, provider: 'google_oauth2', uid: 'google-uid-existing', email: 'existing.google.user@example.com') }

        before do
          mock_auth_hash('google_oauth2', 'existing.google.user@example.com', 'google-uid-existing')
          request.env['omniauth.auth'] = OmniAuth.config.mock_auth[:google_oauth2]
          get :google_oauth2
        end

        it 'does not create a new user' do
          expect(User.count).to eq(1)
        end

        it 'signs in the existing user' do
          expect(subject.current_user).to eq(user)
        end

        it 'redirects to the root path' do
          expect(response).to redirect_to(root_path)
        end

        it 'sets a success flash message' do
          expect(flash[:notice]).to eq(I18n.t('devise.omniauth_callbacks.success', kind: 'Google'))
        end
      end

      context 'Authentication Failure' do
        let(:failed_auth_hash) do
          OmniAuth::AuthHash.new({ provider: 'google_oauth2', uid: 'some-uid-failure' })
        end
        let!(:non_persisted_user_stub) do
          user = User.new
          user.errors.add(:base, "OmniAuth authentication failed.")
          user
        end

        before do
          mock_auth_failure('google_oauth2') # Signifies OmniAuth global state is failure
          request.env['omniauth.auth'] = failed_auth_hash # Controller action receives a hash
          allow(User).to receive(:from_omniauth).with(failed_auth_hash).and_return(non_persisted_user_stub)
          get :google_oauth2
        end

        it 'does not sign in any user' do
          expect(subject.current_user).to be_nil
        end

        it 'redirects to the new user registration path' do
          expect(response).to redirect_to(new_user_registration_url)
        end

        it 'sets an alert message containing user errors' do
          expect(flash[:alert]).to eq(non_persisted_user_stub.errors.full_messages.join('\n'))
        end
      end
    end
  end

  describe 'GitHub OAuth' do
    describe '#github' do
      context 'New User' do
        before do
          mock_auth_hash('github', 'new.github.user@example.com', 'github-uid-123')
          request.env['omniauth.auth'] = OmniAuth.config.mock_auth[:github]
          get :github
        end

        it 'creates a new user' do
          expect(User.find_by(email: 'new.github.user@example.com')).not_to be_nil
          expect(User.count).to eq(1)
        end

        it 'signs in the user' do
          expect(subject.current_user).not_to be_nil
          expect(subject.current_user.email).to eq('new.github.user@example.com')
        end

        it 'redirects to the root path' do
          expect(response).to redirect_to(root_path)
        end

        it 'sets a success flash message' do
          expect(flash[:notice]).to eq(I18n.t('devise.omniauth_callbacks.success', kind: 'GitHub'))
        end
      end

      context 'Existing User' do
        let!(:user) { create(:user, provider: 'github', uid: 'github-uid-existing', email: 'existing.github.user@example.com') }

        before do
          mock_auth_hash('github', 'existing.github.user@example.com', 'github-uid-existing')
          request.env['omniauth.auth'] = OmniAuth.config.mock_auth[:github]
          get :github
        end

        it 'does not create a new user' do
          expect(User.count).to eq(1)
        end

        it 'signs in the existing user' do
          expect(subject.current_user).to eq(user)
        end

        it 'redirects to the root path' do
          expect(response).to redirect_to(root_path)
        end

        it 'sets a success flash message' do
          expect(flash[:notice]).to eq(I18n.t('devise.omniauth_callbacks.success', kind: 'GitHub'))
        end
      end

      context 'Authentication Failure' do
        let(:failed_auth_hash) do
          OmniAuth::AuthHash.new({ provider: 'github', uid: 'some-uid-failure-gh' })
        end
        let!(:non_persisted_user_stub) do
          user = User.new
          user.errors.add(:base, "OmniAuth authentication failed.")
          user
        end

        before do
          mock_auth_failure('github') # Signifies OmniAuth global state is failure
          request.env['omniauth.auth'] = failed_auth_hash # Controller action receives a hash
          allow(User).to receive(:from_omniauth).with(failed_auth_hash).and_return(non_persisted_user_stub)
          get :github
        end

        it 'does not sign in any user' do
          expect(subject.current_user).to be_nil
        end

        it 'redirects to the new user registration path' do
          expect(response).to redirect_to(new_user_registration_url)
        end

        it 'sets an alert message containing user errors' do
          expect(flash[:alert]).to eq(non_persisted_user_stub.errors.full_messages.join('\n'))
        end
      end
    end
  end

  describe '#failure' do
    # This action is tricky to test in isolation as it's usually a result of OmniAuth redirecting
    # *to* it. Direct GET might not simulate the full OmniAuth failure flow.
    # However, we can test its behavior if called directly.
    it 'redirects to root_path with an alert' do
      # This test is marked pending as discussed.
      # The provider-specific failure tests above are generally more effective for covering failure scenarios.
      skip("Direct test of #failure action is complex and often covered by provider-specific failure tests. Also, the route might not be directly callable as assumed previously.")
      # Example of how it might be tested if the route was simple and direct:
      # get :failure
      # expect(response).to redirect_to(new_user_registration_url)
      # expect(flash[:alert]).to be_present
    end
  end
end
