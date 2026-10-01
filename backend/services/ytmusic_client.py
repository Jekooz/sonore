# Modify YTMAuthService to look for config.json in the project root
import json
import os
import keyring
import logging
from ytmusicapi.auth.oauth import OAuthCredentials

logger = logging.getLogger("ytmusic-backend")

YTM_SERVICE_NAME = "ytmusic_client"
CONFIG_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "config.json")

class YTMAuthService:
    def __init__(self):
        self._config = self._load_config()
        self.client_id = self._config.get("client_id")
        self.client_secret = self._config.get("client_secret")

        if not self.client_id or not self.client_secret:
            raise RuntimeError("client_id and client_secret must be provided in config.json")

        self.oauth = OAuthCredentials(self.client_id, self.client_secret)
        self.last_error = None
        self.poll_interval = 10  # default interval
        self.polling = False

    def _load_config(self):
        if not os.path.exists(CONFIG_FILE):
            raise FileNotFoundError(f"Config file {CONFIG_FILE} not found. Please copy config.example.json to config.json and fill in your credentials.")
        with open(CONFIG_FILE, "r") as f:
            return json.load(f)

    def start_oauth_flow(self):
        code_info = self.oauth.get_code()
        return {
            "verification_url": code_info["verification_url"],
            "user_code": code_info["user_code"],
            "device_code": code_info["device_code"]
        }

    def poll_for_token(self, device_code):
        import time
        from ytmusicapi.auth.oauth import OAuthPending, OAuthSlowDown
        sleep_time = 10
        while True:
            try:
                token = self.oauth.token_from_code(device_code)
                self.store_token(token)
                self.last_error = None  # Clear last error on success
                return token
            except OAuthPending as e:
                self.last_error = f"OAuthPending: {e}"
                time.sleep(sleep_time)
            except OAuthSlowDown as e:
                self.last_error = f"OAuthSlowDown: {e}"
                time.sleep(sleep_time + 5)
                sleep_time += 5
            except Exception as e:
                self.last_error = f"{type(e).__name__}: {e}"
                logger.error(f"Error polling for token: {e}")
                raise

    def store_token(self, token):
        keyring.set_password(YTM_SERVICE_NAME, "auth_token", json.dumps(token))

    def get_token(self):
        token_str = keyring.get_password(YTM_SERVICE_NAME, "auth_token")
        if token_str:
            return json.loads(token_str)
        return None
