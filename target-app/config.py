import os
import logging
import sys

# ── Logging ──────────────────────────────────────────────────────────────────
def setup_logging() -> logging.Logger:
    logger = logging.getLogger("target-app")
    logger.setLevel(logging.DEBUG)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter(
        "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S"
    ))
    logger.addHandler(handler)
    return logger

logger = setup_logging()

# ── Config ────────────────────────────────────────────────────────────────────
APP_NAME     = os.getenv("APP_NAME", "target-app")
APP_VERSION  = os.getenv("APP_VERSION", "1.0.0")
PORT         = int(os.getenv("PORT", "8080"))
NAMESPACE    = os.getenv("POD_NAMESPACE", "default")
POD_NAME     = os.getenv("POD_NAME", "unknown")
DASHBOARD_URL = os.getenv("DASHBOARD_URL", "")   # register self on startup
