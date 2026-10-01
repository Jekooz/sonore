from fastapi import FastAPI, BackgroundTasks
from fastapi.responses import JSONResponse
import uvicorn
import os
import tempfile
import logging
from services.ytmusic_client import YTMAuthService

from typing import Dict, Optional

app = FastAPI()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ytmusic-backend")

YTM_SERVICE_NAME = "ytmusic_client"
PORT_FILE = os.path.join(tempfile.gettempdir(), "ytmusic_sidecar_port.txt")

auth_service = YTMAuthService()

@app.get("/health")
def health():
    return JSONResponse(content={"status": "ok"})

@app.get("/auth/status")
def auth_status():
    token = auth_service.get_token()
    return JSONResponse(content={
        "logged_in": token is not None,
        "error": auth_service.last_error
    })

@app.post("/auth/login")
async def auth_login(background_tasks: BackgroundTasks):
    """
    Starts the real ytmusicapi OAuth device-code flow.
    Returns the verification URL and user code for the user to enter on Google.
    """
    try:
        code_info = auth_service.start_oauth_flow()
        verification_url = code_info["verification_url"]
        user_code = code_info["user_code"]
        device_code = code_info["device_code"]

        def poll_google():
            logger.info(f"Starting background polling for device code: {device_code}")
            try:
                token = auth_service.poll_for_token(device_code)
                if token:
                    auth_service.store_token(token)
                    logger.info("Successfully authenticated and stored token.")
            except Exception as e:
                logger.error(f"Polling error: {e}")

        background_tasks.add_task(poll_google)

        return {
            "verification_url": verification_url,
            "user_code": user_code
        }

    except Exception as e:
        logger.exception("Unexpected error during login")
        return JSONResponse(status_code=500, content={"error": str(e)})

if __name__ == "__main__":
    # Get a random port for the backend
    port = 8000  # Fixed for simplicity; can randomize if needed

    # Write port to file
    with open(PORT_FILE, "w") as f:
        f.write(str(port))

    logger.info(f"Starting backend on port {port}")
    uvicorn.run(app, host="127.0.0.1", port=port)