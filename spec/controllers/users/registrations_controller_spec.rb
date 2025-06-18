require 'rails_helper'

RSpec.describe Users::RegistrationsController, type: :controller do
  before do
    # Note: Using @request.env for controller specs, not request.env as in integration specs
    @request.env["devise.mapping"] = Devise.mappings[:user]
  end

  describe "POST #create" do
    context "with valid params" do
      let(:valid_attributes) do
        # Using FactoryBot.attributes_for to get a hash of attributes for a new user.
        # This assumes the :user factory is set up to produce valid attributes.
        # Devise requires password and password_confirmation for direct registration.
        # Ensure your factory or these attributes provide them.
        FactoryBot.attributes_for(:user).merge(password_confirmation: FactoryBot.attributes_for(:user)[:password])
      end

      it "creates a new User" do
        expect {
          post :create, params: { user: valid_attributes }
        }.to change(User, :count).by(1)
      end

      it "redirects to the new_video_creation_path after sign up" do
        post :create, params: { user: valid_attributes }
        # Devise internally calls `after_sign_up_path_for(resource)` after a successful sign-up.
        # The response of the create action will be a redirect to the path returned by this method.
        expect(response).to redirect_to(new_video_creation_path)
      end

      it "signs in the new user" do
        post :create, params: { user: valid_attributes }
        expect(subject.current_user).not_to be_nil
        expect(subject.current_user.email).to eq(valid_attributes[:email])
      end
    end

    context "with invalid params" do
      let(:invalid_attributes) do
        # Example of invalid attributes: blank email
        FactoryBot.attributes_for(:user, email: "").merge(password_confirmation: FactoryBot.attributes_for(:user)[:password])
      end

      it "does not create a new User" do
        expect {
          post :create, params: { user: invalid_attributes }
        }.to_not change(User, :count)
      end

      it "re-renders the 'new' template" do
        post :create, params: { user: invalid_attributes }
        # Depending on how your views are structured, Devise might render 'devise/registrations/new'
        # or just 'new' if you have custom views that don't follow the full Devise path.
        # For a standard Devise setup, it often re-renders the new action's view from within Devise.
        expect(response).to render_template("new")
      end

      it "does not sign in any user" do
        post :create, params: { user: invalid_attributes }
        expect(subject.current_user).to be_nil
      end
    end
  end
end
