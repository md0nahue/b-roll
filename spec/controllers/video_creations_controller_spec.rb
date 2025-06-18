require 'rails_helper'

RSpec.describe VideoCreationsController, type: :controller do
  let(:user) { create(:user) } # Using the previously defined user factory

  before do
    @request.env["devise.mapping"] = Devise.mappings[:user]
  end

  describe "GET #new" do
    context "when user is authenticated" do
      before do
        sign_in user
        get :new
      end

      it "returns a successful response" do
        expect(response).to be_successful
      end

      it "assigns a new VideoCreation to @video_creation" do
        expect(assigns(:video_creation)).to be_a_new(VideoCreation)
      end

      it "builds the video creation for the current user" do
        expect(assigns(:video_creation).user).to eq(user)
      end

      it "renders the new template" do
        expect(response).to render_template(:new)
      end
    end

    context "when user is not authenticated" do
      it "redirects to the sign-in page" do
        get :new
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "POST #create" do
    # Helper to create an uploaded file for tests
    let(:uploaded_file) do
      # Ensure the dummy file exists (as created in model specs)
      fixture_file_path = Rails.root.join('spec', 'fixtures', 'files', 'sample_video.mp4')
      unless File.exist?(fixture_file_path)
        FileUtils.mkdir_p(File.dirname(fixture_file_path))
        File.open(fixture_file_path, 'w') { |f| f.write("dummy video content") }
      end
      Rack::Test::UploadedFile.new(fixture_file_path, 'video/mp4')
    end

    let(:valid_attributes) do
      { title: "Test Video Upload", file: uploaded_file }
    end

    let(:invalid_attributes) do
      { title: "", file: nil } # No title, no file
    end

    context "when user is authenticated" do
      before do
        sign_in user
      end

      context "with valid parameters" do
        it "creates a new VideoCreation for the current user" do
          expect {
            post :create, params: { video_creation: valid_attributes }
          }.to change(user.video_creations, :count).by(1)
        end

        it "attaches the file" do
           post :create, params: { video_creation: valid_attributes }
           expect(VideoCreation.last.file).to be_attached
        end

        it "redirects to the root path" do # As per controller logic
          post :create, params: { video_creation: valid_attributes }
          expect(response).to redirect_to(root_path)
        end

        it "sets a success flash notice" do
          post :create, params: { video_creation: valid_attributes }
          expect(flash[:notice]).to eq('Video was successfully uploaded.')
        end
      end

      context "with invalid parameters" do
        it "does not create a new VideoCreation" do
          expect {
            post :create, params: { video_creation: invalid_attributes }
          }.to_not change(VideoCreation, :count)
        end

        it "re-renders the 'new' template with unprocessable_entity status" do
          post :create, params: { video_creation: invalid_attributes }
          expect(response).to render_template(:new)
          expect(response).to have_http_status(:unprocessable_entity)
        end
      end
    end

    context "when user is not authenticated" do
      it "redirects to the sign-in page" do
        post :create, params: { video_creation: valid_attributes }
        expect(response).to redirect_to(new_user_session_path)
      end

      it "does not create any VideoCreation" do
        expect {
          post :create, params: { video_creation: valid_attributes }
        }.to_not change(VideoCreation, :count)
      end
    end
  end
end
