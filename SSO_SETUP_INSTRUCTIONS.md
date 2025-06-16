# B-Roll AI: Single Sign-On (SSO) Setup Instructions

This document provides instructions on how to set up Google and GitHub Single Sign-On (SSO) for the B-Roll AI application.

## Important Security Note

**Never commit your Client IDs or Client Secrets directly into the repository.** These are sensitive credentials. Use Rails encrypted credentials, environment variables, or a configuration management tool to handle them securely.

For this application, these credentials should be stored using Rails credentials:
`bin/rails credentials:edit`

And then accessed in `config/initializers/devise.rb` like so:
`Rails.application.credentials.google_oauth2[:client_id]`
`Rails.application.credentials.google_oauth2[:client_secret]`
`Rails.application.credentials.github[:client_id]`
`Rails.application.credentials.github[:client_secret]`

The `config/initializers/devise.rb` file has been pre-configured with placeholder strings. You will need to replace these placeholders with the actual calls to Rails credentials as shown above, after you've added the credentials.

## Google SSO Setup

1.  **Go to the Google Cloud Platform Console:**
    *   Navigate to [https://console.cloud.google.com/](https://console.cloud.google.com/).

2.  **Create a new project** (or select an existing one).
    *   Click the project dropdown in the top navigation bar.
    *   Click "New Project".
    *   Enter a project name (e.g., "B-Roll AI Auth") and select an organization/location if applicable.
    *   Click "Create".

3.  **Enable the Google People API:**
    *   Once your project is selected, navigate to "APIs & Services" > "Library".
    *   Search for "Google People API" and enable it for your project. This API is often needed for fetching profile information like email.

4.  **Configure the OAuth consent screen:**
    *   Navigate to "APIs & Services" > "OAuth consent screen".
    *   Choose "External" for User Type (unless you have a Google Workspace account and this app is internal). Click "Create".
    *   Fill in the required information:
        *   **App name:** B-Roll AI (or as you prefer)
        *   **User support email:** Your email address.
        *   **App logo:** (Optional)
        *   **Authorized domains:** Add the domain where your application will be hosted (e.g., `broll-ai.com`). For development, you might use `localhost`.
        *   **Developer contact information:** Your email address.
    *   Click "Save and Continue".
    *   **Scopes:** You don't typically need to add scopes here if they are defined in your application's request (Devise initializer already requests `email` and `profile`). Click "Save and Continue".
    *   **Test users:** (Optional for development) Add any Google accounts that can test the integration while it's in "testing" mode. Click "Save and Continue".
    *   Review the summary and click "Back to Dashboard".
    *   You might need to "Publish" the app later, but for development, "testing" mode is usually fine.

5.  **Create OAuth 2.0 credentials:**
    *   Navigate to "APIs & Services" > "Credentials".
    *   Click "+ Create Credentials" and select "OAuth client ID".
    *   **Application type:** Select "Web application".
    *   **Name:** A descriptive name, e.g., "B-Roll AI Web Client".
    *   **Authorized JavaScript origins:** (Typically not needed for server-side OAuth like with Devise)
    *   **Authorized redirect URIs:** This is crucial.
        *   For development: `http://localhost:3000/users/auth/google_oauth2/callback` (assuming your Rails app runs on port 3000).
        *   For production: `https://your-app-domain.com/users/auth/google_oauth2/callback`
    *   Click "Create".

6.  **Copy your Client ID and Client Secret:**
    *   A dialog will appear showing your "Client ID" and "Client Secret". **Copy these immediately and store them securely.** You will need them for your Rails application's credentials.

7.  **Add Credentials to Rails:**
    *   Run `bin/rails credentials:edit`.
    *   Add the following structure (if it's not already there from other credentials):
        ```yaml
        google_oauth2:
          client_id: YOUR_COPIED_GOOGLE_CLIENT_ID
          client_secret: YOUR_COPIED_GOOGLE_CLIENT_SECRET
        ```
    *   Save and close the credentials file.

8.  **Update `config/initializers/devise.rb`:**
    *   Replace the placeholder for Google:
        ```ruby
        config.omniauth :google_oauth2,
                        Rails.application.credentials.google_oauth2[:client_id],
                        Rails.application.credentials.google_oauth2[:client_secret],
                        { scope: 'email,profile' }
        ```

## GitHub SSO Setup

1.  **Go to GitHub Developer settings:**
    *   Navigate to your GitHub account.
    *   Click on your profile picture in the top-right corner, then "Settings".
    *   In the left sidebar, scroll down and click "Developer settings".

2.  **Register a new OAuth application:**
    *   Click on "OAuth Apps" in the sidebar.
    *   Click the "New OAuth App" button.
    *   Fill in the application details:
        *   **Application name:** B-Roll AI (or as you prefer).
        *   **Homepage URL:**
            *   For development: `http://localhost:3000`
            *   For production: `https://your-app-domain.com`
        *   **Application description:** (Optional) A brief description.
        *   **Authorization callback URL:** This is crucial.
            *   For development: `http://localhost:3000/users/auth/github/callback`
            *   For production: `https://your-app-domain.com/users/auth/github/callback`
    *   Click "Register application".

3.  **Copy your Client ID and Client Secret:**
    *   Once the application is registered, you will see the "Client ID".
    *   Click the "Generate a new client secret" button. **Copy the Client Secret immediately and store it securely.** It will only be shown once.
    *   You will need both the Client ID and Client Secret for your Rails application's credentials.

4.  **Add Credentials to Rails:**
    *   Run `bin/rails credentials:edit`.
    *   Add the following structure:
        ```yaml
        github:
          client_id: YOUR_COPIED_GITHUB_CLIENT_ID
          client_secret: YOUR_COPIED_GITHUB_CLIENT_SECRET
        ```
    *   Save and close the credentials file.

5.  **Update `config/initializers/devise.rb`:**
    *   Replace the placeholder for GitHub:
        ```ruby
        config.omniauth :github,
                        Rails.application.credentials.github[:client_id],
                        Rails.application.credentials.github[:client_secret],
                        { scope: 'user:email' }
        ```

## Final Steps

1.  **Restart your Rails server** after adding credentials and updating `devise.rb` to ensure the changes are loaded.
2.  Test both Google and GitHub SSO flows thoroughly in development and production environments.

Remember to replace `http://localhost:3000` and `https://your-app-domain.com` with your actual development and production URLs.
