## Setting up OAuth client in Google Cloud Console

1. Go to the Google Cloud Console and create a new project.
2. Enable the YouTube Data API v3 for the project.
3. Create a new OAuth client for the project, selecting "TVs and Limited Input devices" as the application type.
4. Note the client ID and client secret for the client.
5. Create a new file named `config.json` in the project root, with the following contents:

```json
{
  "client_id": "YOUR_CLIENT_ID_HERE",
  "client_secret": "YOUR_CLIENT_SECRET_HERE"
}

6. Replace `YOUR_CLIENT_ID_HERE` and `YOUR_CLIENT_SECRET_HERE` with the values from the OAuth client you created in step 4.

7. Run the app again, and it should now use the OAuth client to authenticate with the YouTube API.