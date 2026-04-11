from fastapi import APIRouter, Response
from config import logger, APP_NAME, NAMESPACE, POD_NAME
import chaos.cpu as cpu_chaos
import chaos.memory as mem_chaos
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
