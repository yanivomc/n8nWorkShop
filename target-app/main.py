import httpx
from contextlib import asynccontextmanager
from fastapi import FastAPI
from config import logger, APP_NAME, APP_VERSION, NAMESPACE, POD_NAME, DASHBOARD_URL, PORT
from routes.health import router as health_router
from routes.chaos import router as chaos_router
from routes.metrics import router as metrics_router


async def register_with_dashboard():
    """Register this instance with the central dashboard on startup."""
    if not DASHBOARD_URL:
        logger.info("No DASHBOARD_URL set — skipping registration")
        return
    try:
        payload = {
            "app": APP_NAME,
            "version": APP_VERSION,
            "namespace": NAMESPACE,
            "pod": POD_NAME,
            "port": PORT,
        }
        async with httpx.AsyncClient(timeout=5) as client:
            r = await client.post(f"{DASHBOARD_URL}/api/register", json=payload)
            logger.info(f"Registered with dashboard | status={r.status_code}")
    except Exception as e:
        logger.warning(f"Dashboard registration failed (non-fatal): {e}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(f"Starting {APP_NAME} v{APP_VERSION} | pod={POD_NAME} ns={NAMESPACE}")
    await register_with_dashboard()
    yield
    logger.info(f"Shutting down {APP_NAME}")


app = FastAPI(
    title=APP_NAME,
    version=APP_VERSION,
    description="Chaos target app for n8n DevOps Workshop",
    lifespan=lifespan,
)

app.include_router(health_router)
app.include_router(chaos_router)
app.include_router(metrics_router)

logger.info("Routes registered: /health /ready /info /metrics /chaos/*")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=PORT, log_level="info")
