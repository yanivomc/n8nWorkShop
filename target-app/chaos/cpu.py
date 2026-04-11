import threading
import time
from config import logger

_cpu_threads: list[threading.Thread] = []
_stop_event = threading.Event()
_active = False


def _burn(stop: threading.Event):
    """Busy-loop on a single core until stop is set."""
    while not stop.is_set():
        _ = sum(i * i for i in range(10000))


def start_cpu_stress(cores: int = 1, duration_seconds: int = 60):
    """Spin up `cores` threads burning CPU. Auto-stops after duration."""
    global _cpu_threads, _stop_event, _active
    try:
        if _active:
            logger.warning("CPU stress already active — stopping first")
            stop_cpu_stress()

        _stop_event = threading.Event()
        _cpu_threads = []
        _active = True

        for i in range(cores):
            t = threading.Thread(target=_burn, args=(_stop_event,), daemon=True)
            t.start()
            _cpu_threads.append(t)

        logger.info(f"CPU stress started | cores={cores} duration={duration_seconds}s")

        # Auto-stop after duration
        def auto_stop():
            time.sleep(duration_seconds)
            stop_cpu_stress()
            logger.info("CPU stress auto-stopped after duration")

        threading.Thread(target=auto_stop, daemon=True).start()

    except Exception as e:
        logger.error(f"CPU stress start failed: {e}")
        _active = False
        raise


def stop_cpu_stress():
    global _active
    try:
        _stop_event.set()
        _active = False
        logger.info("CPU stress stopped")
    except Exception as e:
        logger.error(f"CPU stress stop failed: {e}")


def is_active() -> bool:
    return _active
