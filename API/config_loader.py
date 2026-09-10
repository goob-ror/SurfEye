"""
Configuration loader for SurfEye API.
Loads settings from .env file and environment variables.
"""

import os
from pathlib import Path
from dotenv import load_dotenv

# Load .env file from API directory
API_DIR = Path(__file__).parent
load_dotenv(API_DIR / ".env")


# -------------------------------------------------------------------
# Server Configuration
# -------------------------------------------------------------------

PORT = int(os.getenv("PORT", "8000"))
NO_NGROK = os.getenv("NO_NGROK", "false").lower() == "true"
DEBUG = os.getenv("DEBUG", "false").lower() == "true"
NGROK_AUTHTOKEN = os.getenv("NGROK_AUTHTOKEN")


# -------------------------------------------------------------------
# Ngrok Configuration
# -------------------------------------------------------------------

def get_ngrok_token():
    """Get ngrok auth token from environment or return None."""
    return NGROK_AUTHTOKEN


def is_ngrok_disabled():
    """Check if ngrok tunneling is disabled."""
    return NO_NGROK
