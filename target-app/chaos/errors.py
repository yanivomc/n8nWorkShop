import threading
import time
import random
from config import logger

_error_active = False
_error_rate = 1.0  # fraction of requests that fail (1.0 = 100%)
_latency_active = False
_latency_ms = 0
_lock = threading.Lock()

# Counters for metrics
_http_errors_total = 0
_http_requests_total = 0

def start_error_rate(rate: float = 1.0):
    global _error_active, _error_rate
    with _lock:
        _error_active = True
        _error_rate = min(max(rate, 0.0), 1.0)
    logger.warning(f"Error rate chaos started | rate={_error_rate*100:.0f}%")

def stop_error_rate():
    global _error_active, _error_rate
    with _lock:
        _error_active = False
        _error_rate = 0.0
    logger.info("Error rate chaos stopped")

def start_latency(latency_ms: int = 2000):
    global _latency_active, _latency_ms
    with _lock:
        _latency_active = True
        _latency_ms = latency_ms
    logger.warning(f"Latency chaos started | delay={latency_ms}ms")

def stop_latency():
    global _latency_active, _latency_ms
    with _lock:
        _latency_active = False
        _latency_ms = 0
    logger.info("Latency chaos stopped")

def is_error_active() -> bool:
    return _error_active

def is_latency_active() -> bool:
    return _latency_active

def get_error_rate() -> float:
    return _error_rate

def get_latency_ms() -> int:
    return _latency_ms

def should_fail() -> bool:
    """Call from request handlers — returns True if this request should return 500."""
    if not _error_active:
        return False
    return random.random() < _error_rate

def inject_latency():
    """Call from request handlers — sleeps if latency chaos is active."""
    if _latency_active and _latency_ms > 0:
        time.sleep(_latency_ms / 1000.0)

def record_request(is_error: bool):
    global _http_requests_total, _http_errors_total
    with _lock:
        _http_requests_total += 1
        if is_error:
            _http_errors_total += 1

def get_error_count() -> int:
    return _http_errors_total

def get_request_count() -> int:
    return _http_requests_total
