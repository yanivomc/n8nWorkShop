from fastapi import APIRouter
from pydantic import BaseModel
from config import logger
import chaos.cpu as cpu_chaos
import chaos.memory as mem_chaos
import chaos.crash as crash_chaos

router = APIRouter(prefix="/chaos")


class CpuRequest(BaseModel):
    cores: int = 1
    duration_seconds: int = 60


class MemoryRequest(BaseModel):
    mb_per_second: int = 50
    max_mb: int = 500


class CrashRequest(BaseModel):
    delay_seconds: int = 5


@router.post("/cpu")
def trigger_cpu(req: CpuRequest):
    try:
        cpu_chaos.start_cpu_stress(req.cores, req.duration_seconds)
        logger.info(f"Chaos CPU triggered | cores={req.cores} duration={req.duration_seconds}s")
        return {"status": "started", "scenario": "cpu", "cores": req.cores, "duration_seconds": req.duration_seconds}
    except Exception as e:
        logger.error(f"Chaos CPU error: {e}")
        return {"status": "error", "detail": str(e)}, 500


@router.delete("/cpu")
def stop_cpu():
    try:
        cpu_chaos.stop_cpu_stress()
        return {"status": "stopped", "scenario": "cpu"}
    except Exception as e:
        logger.error(f"Stop CPU error: {e}")
        return {"status": "error", "detail": str(e)}, 500


@router.post("/memory")
def trigger_memory(req: MemoryRequest):
    try:
        mem_chaos.start_memory_leak(req.mb_per_second, req.max_mb)
        logger.info(f"Chaos Memory triggered | rate={req.mb_per_second}MB/s max={req.max_mb}MB")
        return {"status": "started", "scenario": "memory", "mb_per_second": req.mb_per_second, "max_mb": req.max_mb}
    except Exception as e:
        logger.error(f"Chaos Memory error: {e}")
        return {"status": "error", "detail": str(e)}, 500


@router.delete("/memory")
def stop_memory():
    try:
        mem_chaos.stop_memory_leak()
        return {"status": "stopped", "scenario": "memory"}
    except Exception as e:
        logger.error(f"Stop Memory error: {e}")
        return {"status": "error", "detail": str(e)}, 500


@router.post("/crash")
def trigger_crash(req: CrashRequest):
    try:
        logger.warning(f"Chaos CRASH triggered | delay={req.delay_seconds}s")
        crash_chaos.start_crash(req.delay_seconds)
        return {"status": "scheduled", "scenario": "crash", "delay_seconds": req.delay_seconds}
    except Exception as e:
        logger.error(f"Chaos Crash error: {e}")
        return {"status": "error", "detail": str(e)}, 500


@router.post("/error-loop")
def trigger_error_loop():
    try:
        crash_chaos.start_error_loop()
        return {"status": "started", "scenario": "error-loop"}
    except Exception as e:
        logger.error(f"Error loop trigger failed: {e}")
        return {"status": "error", "detail": str(e)}, 500


@router.delete("/error-loop")
def stop_error_loop():
    try:
        crash_chaos.stop_error_loop()
        return {"status": "stopped", "scenario": "error-loop"}
    except Exception as e:
        logger.error(f"Stop error loop failed: {e}")
        return {"status": "error", "detail": str(e)}, 500


@router.get("/status")
def chaos_status():
    try:
        return {
            "cpu_active": cpu_chaos.is_active(),
            "memory_active": mem_chaos.is_active(),
            "memory_current_mb": mem_chaos.current_mb(),
        }
    except Exception as e:
        logger.error(f"Status check error: {e}")
        return {"status": "error", "detail": str(e)}, 500


@router.delete("/all")
def stop_all():
    try:
        cpu_chaos.stop_cpu_stress()
        mem_chaos.stop_memory_leak()
        crash_chaos.stop_error_loop()
        error_chaos.stop_error_rate()
        error_chaos.stop_latency()
        logger.info("All chaos stopped")
        return {"status": "all stopped"}
    except Exception as e:
        logger.error(f"Stop all error: {e}")
        return {"status": "error", "detail": str(e)}, 500


import chaos.errors as error_chaos

class ErrorRateRequest(BaseModel):
    rate: float = 1.0  # 0.0-1.0

class LatencyRequest(BaseModel):
    latency_ms: int = 2000

@router.post("/error-rate")
def trigger_error_rate(req: ErrorRateRequest):
    try:
        error_chaos.start_error_rate(req.rate)
        return {"status": "started", "scenario": "error-rate", "rate": req.rate}
    except Exception as e:
        return {"status": "error", "detail": str(e)}, 500

@router.delete("/error-rate")
def stop_error_rate():
    try:
        error_chaos.stop_error_rate()
        return {"status": "stopped", "scenario": "error-rate"}
    except Exception as e:
        return {"status": "error", "detail": str(e)}, 500

@router.post("/latency")
def trigger_latency(req: LatencyRequest):
    try:
        error_chaos.start_latency(req.latency_ms)
        return {"status": "started", "scenario": "latency", "latency_ms": req.latency_ms}
    except Exception as e:
        return {"status": "error", "detail": str(e)}, 500

@router.delete("/latency")
def stop_latency():
    try:
        error_chaos.stop_latency()
        return {"status": "stopped", "scenario": "latency"}
    except Exception as e:
        return {"status": "error", "detail": str(e)}, 500
