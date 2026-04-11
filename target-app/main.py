import asyncio
import httpx
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from config import logger, APP_NAME, APP_VERSION, NAMESPACE, POD_NAME, DASHBOARD_URL, PORT
from routes.health import router as health_router
from routes.chaos import router as chaos_router
from routes.metrics import router as metrics_router


async def register_with_dashboard():
    """Register this instance with the central dashboard on startup."""
    import os
    if os.getenv("SKIP_REGISTRATION", "false").lower() == "true":
        logger.info("SKIP_REGISTRATION=true — skipping dashboard registration")
        return
    if not DASHBOARD_URL:
        logger.info("No DASHBOARD_URL set — skipping registration")
        return

    payload = {
        "app": APP_NAME,
        "version": APP_VERSION,
        "namespace": NAMESPACE,
        "pod": POD_NAME,
        "port": PORT,
        "public_url": os.getenv("PUBLIC_URL", ""),  # e.g. http://EC2_IP:30080
    }

    max_retries = 10
    retry_delay = 5
    for attempt in range(1, max_retries + 1):
        try:
            async with httpx.AsyncClient(timeout=5) as client:
                r = await client.post(f"{DASHBOARD_URL}/api/register", json=payload)
            logger.info(f"Registered with dashboard | status={r.status_code} | attempt={attempt}")
            return
        except Exception as e:
            logger.warning(f"Dashboard registration attempt {attempt}/{max_retries} failed: {e}")
            if attempt < max_retries:
                logger.info(f"Retrying in {retry_delay}s...")
                await asyncio.sleep(retry_delay)

    logger.error(f"Dashboard registration failed after {max_retries} attempts — exiting so K8s restarts pod")
    import sys
    sys.exit(1)


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

# Allow dashboard (any origin) to call the API from the browser
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_router)
app.include_router(chaos_router)
app.include_router(metrics_router)

@app.get("/")
def root():
    return {"app": APP_NAME, "version": APP_VERSION, "status": "ok"}

logger.info("Routes registered: /health /ready /info /metrics /chaos/*")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=PORT, log_level="info")
