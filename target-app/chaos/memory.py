import threading
import time
from config import logger

_leak_data: list = []
_active = False
_lock = threading.Lock()


def start_memory_leak(mb_per_second: int = 50, max_mb: int = 500):
    """Allocate `mb_per_second` MB every second up to `max_mb` MB."""
    global _active
    try:
        if _active:
            logger.warning("Memory leak already active — stopping first")
            stop_memory_leak()

        _active = True
        logger.info(f"Memory leak started | rate={mb_per_second}MB/s max={max_mb}MB")

        def leak():
            total = 0
            while _active and total < max_mb:
                try:
                    chunk = bytearray(mb_per_second * 1024 * 1024)
                    with _lock:
                        _leak_data.append(chunk)
                    total += mb_per_second
                    logger.debug(f"Memory allocated: {total}MB")
                    time.sleep(1)
                except MemoryError:
                    logger.error("MemoryError — stopping leak")
                    break
            logger.info(f"Memory leak done | total={total}MB")

        threading.Thread(target=leak, daemon=True).start()
    except Exception as e:
        logger.error(f"Memory leak start failed: {e}")
        _active = False
        raise


def stop_memory_leak():
    global _active
    try:
        _active = False
        with _lock:
            _leak_data.clear()
        logger.info("Memory leak stopped + cleared")
    except Exception as e:
        logger.error(f"Memory leak stop failed: {e}")


def current_mb() -> int:
    try:
        with _lock:
            return sum(len(b) for b in _leak_data) // (1024 * 1024)
    except Exception:
        return 0


def is_active() -> bool:
    return _active
