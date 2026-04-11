import asyncio
import os
import httpx
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from config import logger, APP_NAME, APP_VERSION, NAMESPACE, POD_NAME, DASHBOARD_URL, PORT
from routes.health import router as health_router
from routes.chaos import router as chaos_router
from routes.metrics import router as metrics_router


async def registration_loop():
    """Continuously register with dashboard. Reconnects if dashboard restarts."""
    if os.getenv("SKIP_REGISTRATION", "false").lower() == "true":
        logger.info("SKIP_REGISTRATION=true — skipping")
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
    }

    registered = False
    attempt = 0
    while True:
        attempt += 1
        try:
            async with httpx.AsyncClient(timeout=5) as client:
                r = await client.post(f"{DASHBOARD_URL}/api/register", json=payload)
            if r.status_code == 200:
                if not registered:
                    logger.info(f"REGISTERED with dashboard | attempt={attempt}")
                    registered = True
                    attempt = 0
                else:
                    logger.debug(f"HEARTBEAT to dashboard | ok")
                await asyncio.sleep(30)  # re-register every 30s (handles dashboard restarts)
            else:
                logger.warning(f"Registration failed | status={r.status_code} | retrying in 5s")
                registered = False
                await asyncio.sleep(5)
        except Exception as e:
            registered = False
            logger.warning(f"Dashboard unreachable | attempt={attempt} | {e} | retrying in 5s")
            await asyncio.sleep(5)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(f"Starting {APP_NAME} v{APP_VERSION} | pod={POD_NAME} ns={NAMESPACE}")
    # Run registration as background task — doesn't block startup
    task = asyncio.create_task(registration_loop())
    yield
    task.cancel()
    logger.info(f"Shutting down {APP_NAME}")


app = FastAPI(
    title=APP_NAME,
    version=APP_VERSION,
    description="Chaos target app for n8n DevOps Workshop",
    lifespan=lifespan,
)

app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.include_router(health_router)
app.include_router(chaos_router)
app.include_router(metrics_router)

@app.get("/")
def root():
    return {"app": APP_NAME, "version": APP_VERSION, "status": "ok"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=PORT, log_level="info")
