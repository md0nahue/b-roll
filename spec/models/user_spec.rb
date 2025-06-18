require 'rails_helper'

RSpec.describe User, type: :model do
  describe 'validations' do
    it 'is valid with a correct email and password' do
      user = build(:user)
      expect(user).to be_valid
    end

    it 'is invalid without an email' do
      user = build(:user, email: nil)
      expect(user).not_to be_valid
      expect(user.errors[:email]).to include("can't be blank")
    end

    it 'is invalid without a password for new records' do
      user = build(:user, password: nil)
      expect(user).not_to be_valid
      expect(user.errors[:password]).to include("can't be blank")
    end
  end

  describe '.from_omniauth' do
    before do
      OmniAuth.config.test_mode = true
    end

    after do
      OmniAuth.config.test_mode = false
      OmniAuth.config.mock_auth[:google_oauth2] = nil
      OmniAuth.config.mock_auth[:github] = nil
    end

    context 'New User (Google)' do
      let(:auth_hash) do
        OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new({
          provider: 'google_oauth2',
          uid: '123456789',
          info: {
            email: 'new_google_user@example.com'
          }
        })
      end

      it 'creates a new user' do
        expect { User.from_omniauth(auth_hash) }.to change(User, :count).by(1)
      end

      it 'sets the email, provider, and uid correctly' do
        user = User.from_omniauth(auth_hash)
        expect(user.email).to eq('new_google_user@example.com')
        expect(user.provider).to eq('google_oauth2')
        expect(user.uid).to eq('123456789')
      end
    end

    context 'Existing User (Google)' do
      let!(:existing_user) { create(:user, provider: 'google_oauth2', uid: '123456789', email: 'existing_google_user@example.com') }
      let(:auth_hash) do
        OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new({
          provider: 'google_oauth2',
          uid: '123456789',
          info: {
            email: 'existing_google_user@example.com' # This email might be different in a real scenario if updated on Google
          }
        })
      end

      it 'returns the existing user' do
        expect(User.from_omniauth(auth_hash)).to eq(existing_user)
      end

      it 'does not create a new user' do
        expect { User.from_omniauth(auth_hash) }.not_to change(User, :count)
      end
    end

    context 'New User (GitHub)' do
      let(:auth_hash) do
        OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new({
          provider: 'github',
          uid: '987654321',
          info: {
            email: 'new_github_user@example.com'
          }
        })
      end

      it 'creates a new user' do
        expect { User.from_omniauth(auth_hash) }.to change(User, :count).by(1)
      end

      it 'sets the email, provider, and uid correctly' do
        user = User.from_omniauth(auth_hash)
        expect(user.email).to eq('new_github_user@example.com')
        expect(user.provider).to eq('github')
        expect(user.uid).to eq('987654321')
      end
    end

    context 'Existing User (GitHub)' do
      let!(:existing_user) { create(:user, provider: 'github', uid: '987654321', email: 'existing_github_user@example.com') }
      let(:auth_hash) do
        OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new({
          provider: 'github',
          uid: '987654321',
          info: {
            email: 'existing_github_user@example.com' # This email might be different if updated on GitHub
          }
        })
      end

      it 'returns the existing user' do
        expect(User.from_omniauth(auth_hash)).to eq(existing_user)
      end

      it 'does not create a new user' do
        expect { User.from_omniauth(auth_hash) }.not_to change(User, :count)
      end
    end
  end

  describe 'associations' do
    it { should have_many(:video_creations) }
  end
end
