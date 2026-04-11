from fastapi import APIRouter
from config import logger, APP_NAME, APP_VERSION, NAMESPACE, POD_NAME
import time

router = APIRouter()
_start_time = time.time()
_unhealthy = False


def set_unhealthy(state: bool):
    global _unhealthy
    _unhealthy = state
    logger.warning(f"Health state set to {'UNHEALTHY' if state else 'HEALTHY'}")


@router.get("/health")
def health():
    try:
        if _unhealthy:
            logger.warning("Health check: UNHEALTHY")
            return {"status": "unhealthy", "app": APP_NAME}, 500
        return {"status": "ok", "app": APP_NAME, "version": APP_VERSION}
    except Exception as e:
        logger.error(f"Health check error: {e}")
        return {"status": "error", "detail": str(e)}, 500


@router.get("/ready")
def ready():
    try:
        if _unhealthy:
            return {"status": "not ready"}, 503
        return {"status": "ready"}
    except Exception as e:
        logger.error(f"Readiness check error: {e}")
        return {"status": "error"}, 503


@router.get("/info")
def info():
    try:
        return {
            "app": APP_NAME,
            "version": APP_VERSION,
            "namespace": NAMESPACE,
            "pod": POD_NAME,
            "uptime_seconds": round(time.time() - _start_time),
        }
    except Exception as e:
        logger.error(f"Info endpoint error: {e}")
        return {"error": str(e)}, 500
