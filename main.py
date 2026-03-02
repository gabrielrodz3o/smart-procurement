import os
import asyncio
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger

load_dotenv()

from routers import forecast, anomalies, explain, supplier_rank, generate, feedback
from models.db import ping_db

scheduler = AsyncIOScheduler()


async def _nightly_generate():
    """
    Nightly job: runs /generate for all configured business units at 2:00 AM.
    Reads NIGHTLY_UNITS env var: comma-separated 'bu_id:location_id' pairs.
    Example: NIGHTLY_UNITS=16:12,17:15
    """
    units_raw = os.getenv("NIGHTLY_UNITS", "")
    if not units_raw:
        print("[scheduler] NIGHTLY_UNITS not set — skipping nightly generate")
        return

    from routers.generate import generate_suggestions, GenerateRequest
    for pair in units_raw.split(","):
        pair = pair.strip()
        if ":" not in pair:
            continue
        try:
            bu_id, loc_id = pair.split(":")
            req = GenerateRequest(
                business_unit_id=int(bu_id),
                location_id=int(loc_id),
                urgency_threshold=5,
                days_ahead=14,
                lookback_days=180,
            )
            result = await generate_suggestions(req)
            print(f"[scheduler] ✅ nightly generate bu={bu_id} loc={loc_id} → {result.total_suggestions} suggestions")
        except Exception as e:
            print(f"[scheduler] ⚠️  nightly generate failed for {pair}: {e}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db_ok = await ping_db()
    if db_ok:
        print("✅ Database connection OK")
    else:
        print("⚠️  Database connection FAILED — check .env credentials")

    # Start nightly job at 02:00 AM server time
    scheduler.add_job(_nightly_generate, CronTrigger(hour=2, minute=0), id="nightly_generate", replace_existing=True)
    scheduler.start()
    print("✅ Scheduler started — nightly /generate at 02:00 AM")

    yield

    scheduler.shutdown(wait=False)


app = FastAPI(
    title="Purchasing AI Microservice",
    description="Prophet forecasting, anomaly detection, LLM explanations and supplier ranking for smart procurement.",
    version="1.0.0",
    lifespan=lifespan,
    redirect_slashes=False,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(generate.router)
app.include_router(forecast.router)
app.include_router(anomalies.router)
app.include_router(explain.router)
app.include_router(supplier_rank.router)
app.include_router(feedback.router)


@app.get("/health", tags=["health"])
async def health():
    db_ok = await ping_db()
    return {
        "status": "ok",
        "db_connected": db_ok,
        "models_loaded": ["prophet", "isolation_forest"],
        "version": "1.0.0",
    }
