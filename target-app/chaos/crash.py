import threading
import time
import os
import signal
from config import logger


def start_crash(delay_seconds: int = 5):
    """Force process exit after delay — K8s will restart the pod."""
    try:
        logger.warning(f"CRASH scheduled in {delay_seconds}s — pod will restart")

        def _do_crash():
            time.sleep(delay_seconds)
            logger.warning("CRASH NOW — sending SIGKILL to self")
            os.kill(os.getpid(), signal.SIGKILL)

        threading.Thread(target=_do_crash, daemon=True).start()
    except Exception as e:
        logger.error(f"Crash trigger failed: {e}")
        raise


def start_error_loop(error_rate: float = 1.0):
    """Make the app return errors on /health — triggers readiness probe failure."""
    from routes import health as h
    try:
        h.set_unhealthy(True)
        logger.warning(f"Error loop started — /health will return 500")
    except Exception as e:
        logger.error(f"Error loop start failed: {e}")
        raise


def stop_error_loop():
    from routes import health as h
    try:
        h.set_unhealthy(False)
        logger.info("Error loop stopped — /health restored")
    except Exception as e:
        logger.error(f"Error loop stop failed: {e}")
