from fastapi import APIRouter, Response
from config import logger, APP_NAME, NAMESPACE, POD_NAME
import chaos.cpu as cpu_chaos
import chaos.memory as mem_chaos
import chaos.errors as error_chaos
import time

router = APIRouter()
_start_time = time.time()


def _build_metrics() -> str:
    """Build Prometheus text format metrics."""
    try:
        lines = []

        # App info
        lines += [
            f'# HELP target_app_info Target app metadata',
            f'# TYPE target_app_info gauge',
            f'target_app_info{{app="{APP_NAME}",namespace="{NAMESPACE}",pod="{POD_NAME}"}} 1',
        ]

        # Uptime
        uptime = round(time.time() - _start_time)
        lines += [
            f'# HELP target_app_uptime_seconds Seconds since app started',
            f'# TYPE target_app_uptime_seconds counter',
            f'target_app_uptime_seconds {uptime}',
        ]

        # CPU chaos
        cpu_active = 1 if cpu_chaos.is_active() else 0
        lines += [
            f'# HELP target_chaos_cpu_active Whether CPU stress is active',
            f'# TYPE target_chaos_cpu_active gauge',
            f'target_chaos_cpu_active{{namespace="{NAMESPACE}",pod="{POD_NAME}"}} {cpu_active}',
        ]

        # Memory chaos
        mem_active = 1 if mem_chaos.is_active() else 0
        mem_mb = mem_chaos.current_mb()
        lines += [
            f'# HELP target_chaos_memory_active Whether memory leak is active',
            f'# TYPE target_chaos_memory_active gauge',
            f'target_chaos_memory_active{{namespace="{NAMESPACE}",pod="{POD_NAME}"}} {mem_active}',
            f'# HELP target_chaos_memory_bytes Bytes allocated by memory chaos',
            f'# TYPE target_chaos_memory_bytes gauge',
            f'target_chaos_memory_bytes{{namespace="{NAMESPACE}",pod="{POD_NAME}"}} {mem_mb * 1024 * 1024}',
        ]

        # Error rate chaos
        err_active = 1 if error_chaos.is_error_active() else 0
        lines += [
            f'# HELP target_chaos_error_active Whether error rate chaos is active',
            f'# TYPE target_chaos_error_active gauge',
            f'target_chaos_error_active{{namespace="{NAMESPACE}",pod="{POD_NAME}"}} {err_active}',
            f'# HELP target_chaos_error_rate Current error rate (0-1)',
            f'# TYPE target_chaos_error_rate gauge',
            f'target_chaos_error_rate{{namespace="{NAMESPACE}",pod="{POD_NAME}"}} {error_chaos.get_error_rate()}',
            f'# HELP target_http_errors_total Total HTTP errors injected',
            f'# TYPE target_http_errors_total counter',
            f'target_http_errors_total{{namespace="{NAMESPACE}",pod="{POD_NAME}"}} {error_chaos.get_error_count()}',
            f'# HELP target_http_requests_total Total HTTP requests tracked',
            f'# TYPE target_http_requests_total counter',
            f'target_http_requests_total{{namespace="{NAMESPACE}",pod="{POD_NAME}"}} {error_chaos.get_request_count()}',
        ]

        # Latency chaos
        lat_active = 1 if error_chaos.is_latency_active() else 0
        lines += [
            f'# HELP target_chaos_latency_active Whether latency chaos is active',
            f'# TYPE target_chaos_latency_active gauge',
            f'target_chaos_latency_active{{namespace="{NAMESPACE}",pod="{POD_NAME}"}} {lat_active}',
            f'# HELP target_chaos_latency_ms Current injected latency in ms',
            f'# TYPE target_chaos_latency_ms gauge',
            f'target_chaos_latency_ms{{namespace="{NAMESPACE}",pod="{POD_NAME}"}} {error_chaos.get_latency_ms()}',
        ]

        return "\n".join(lines) + "\n"
    except Exception as e:
        logger.error(f"Metrics build error: {e}")
        return f"# ERROR building metrics: {e}\n"


@router.get("/metrics")
def metrics():
    try:
        content = _build_metrics()
        return Response(content=content, media_type="text/plain; version=0.0.4")
    except Exception as e:
        logger.error(f"Metrics endpoint error: {e}")
        return Response(content=f"# error: {e}\n", media_type="text/plain", status_code=500)
