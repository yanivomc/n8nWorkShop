from fastapi import APIRouter
from fastapi.responses import JSONResponse
from config import logger, APP_NAME, APP_VERSION, NAMESPACE, POD_NAME
import time, os

router = APIRouter()
_start_time = time.time()
_FLAG = "/tmp/.unhealthy"

def set_unhealthy(state: bool):
    if state:
        open(_FLAG, "w").close()
        logger.warning("Health state set to UNHEALTHY")
    else:
        try: os.remove(_FLAG)
        except: pass
        logger.warning("Health state set to HEALTHY")

@router.get("/health")
def health():
    try:
        if os.path.exists(_FLAG):
            logger.warning("Health check: UNHEALTHY")
            return JSONResponse({"status": "unhealthy", "app": APP_NAME, "version": APP_VERSION}, status_code=500)
        return {"status": "ok", "app": APP_NAME, "version": APP_VERSION}
    except Exception as e:
        logger.error(f"Health check error: {e}")
        return JSONResponse({"status": "error", "detail": str(e)}, status_code=500)

@router.get("/ready")
def ready():
    if os.path.exists(_FLAG):
        return JSONResponse({"status": "not ready"}, status_code=503)
    return {"status": "ready"}

@router.get("/info")
def info():
    return {"app": APP_NAME, "version": APP_VERSION, "namespace": NAMESPACE, "pod": POD_NAME, "uptime_seconds": round(time.time() - _start_time)}
