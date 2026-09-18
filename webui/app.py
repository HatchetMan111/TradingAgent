"""TradingAgents Proxmox Web UI — thin FastAPI wrapper around the TradingAgents Python API.

Runs inside the LXC container as a systemd service (tradingagents-web.service),
listens on 0.0.0.0:8080, and lets the user configure + launch analyses
without touching the CLI.

Design notes:
- TradingAgents itself has NO native web UI (interactive Typer/Questionary CLI
  only), so this wrapper drives the documented Python API:
      from tradingagents.graph.trading_graph import TradingAgentsGraph
      from tradingagents.default_config import DEFAULT_CONFIG
      ta = TradingAgentsGraph(debug=True, config=config)
      _, decision = ta.propagate(ticker, date)
- `tradingagents` is imported LAZILY inside the worker thread so the Web UI
  still starts (with a clear warning banner) even if the framework install
  failed — important for debugging from the browser.
- Long analyses run in background threads; the frontend polls /api/status.
- API keys are stored in /opt/tradingagents/.env (mode 600) and NEVER
  returned by any GET endpoint — only "set"/"empty" flags.
"""

from __future__ import annotations

import datetime
import json
import os
import threading
import traceback
import uuid
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

BASE_DIR = Path(os.environ.get("TA_BASE_DIR", "/opt/tradingagents"))
SRC_DIR = BASE_DIR / "src" / "TradingAgents"
ENV_FILE = BASE_DIR / ".env"
SETTINGS_FILE = BASE_DIR / "webui-settings.json"
RESULTS_DIR_DEFAULT = str(Path.home() / "results")

API_KEY_FIELDS = [
    "OPENAI_API_KEY",
    "GOOGLE_API_KEY",
    "ANTHROPIC_API_KEY",
    "XAI_API_KEY",
    "DEEPSEEK_API_KEY",
    "OPENROUTER_API_KEY",
    "DASHSCOPE_API_KEY",
    "DASHSCOPE_CN_API_KEY",
    "ZHIPU_API_KEY",
    "ZHIPU_CN_API_KEY",
    "MINIMAX_API_KEY",
    "MINIMAX_CN_API_KEY",
    "MISTRAL_API_KEY",
    "MOONSHOT_API_KEY",
    "GROQ_API_KEY",
    "NVIDIA_API_KEY",
    "ALPHA_VANTAGE_API_KEY",
    "FRED_API_KEY",
]

PROVIDERS = [
    "openai",
    "google",
    "anthropic",
    "xai",
    "deepseek",
    "qwen",
    "glm",
    "minimax",
    "openrouter",
    "mistral",
    "moonshot",
    "groq",
    "nvidia",
    "ollama",
    "openai_compatible",
    "bedrock",
    "azure",
]

app = FastAPI(title="TradingAgents Web UI", version="1.0.0")

_jobs: dict[str, dict] = {}
_jobs_lock = threading.Lock()


# ---------------------------------------------------------------- models ---

class AnalyzeRequest(BaseModel):
    ticker: str = Field(default="SPY", min_length=1, max_length=20)
    date: str = Field(default_factory=lambda: datetime.date.today().isoformat())
    llm_provider: str = "openai"
    deep_think_llm: str = ""
    quick_think_llm: str = ""
    max_debate_rounds: int = Field(default=1, ge=1, le=5)
    max_risk_rounds: int = Field(default=1, ge=1, le=5)
    output_language: str = "English"
    analysts: list[str] = Field(default_factory=lambda: ["market", "social", "news", "fundamentals"])
    checkpoint_enabled: bool = False
    backend_url: str = ""


class ConfigSaveRequest(BaseModel):
    llm_provider: str = "openai"
    backend_url: str = ""
    deep_think_llm: str = ""
    quick_think_llm: str = ""
    output_language: str = "English"
    keys: dict[str, str] = Field(default_factory=dict)


# -------------------------------------------------------------- helpers ---

def load_dotenv_file() -> dict[str, str]:
    data: dict[str, str] = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            data[k.strip()] = v.strip().strip("'\"")
    return data


def write_dotenv_file(updates: dict[str, str]) -> None:
    current = load_dotenv_file()
    current.update({k: v for k, v in updates.items() if v})
    lines = ["# Managed by TradingAgents Web UI — edit via http://<LXC-IP>:8080\n"]
    for k in sorted(current):
        lines.append(f"{k}={current[k]}")
    ENV_FILE.write_text("\n".join(lines) + "\n")
    try:
        os.chmod(ENV_FILE, 0o600)
    except OSError:
        pass
    for k, v in current.items():
        if v:
            os.environ[k] = v


def framework_available() -> tuple[bool, str]:
    """Check whether the TradingAgents package imports. Returns (ok, detail)."""
    try:
        import tradingagents  # noqa: F401
        from tradingagents.default_config import DEFAULT_CONFIG  # noqa: F401

        return True, "ok"
    except Exception as exc:  # noqa: BLE001 — full chain goes to the caller
        return False, f"{type(exc).__name__}: {exc}"


def run_analysis_job(job_id: str, req: AnalyzeRequest) -> None:
    """Worker thread: full error chain is always captured into the job log."""
    log_lines: list[str] = []

    def log(msg: str) -> None:
        line = f"[{datetime.datetime.now().isoformat(timespec='seconds')}] {msg}"
        log_lines.append(line)
        with _jobs_lock:
            _jobs[job_id]["log"] = "\n".join(log_lines)

    def set_state(**kw) -> None:
        with _jobs_lock:
            _jobs[job_id].update(kw)

    set_state(status="running")
    try:
        log(f"Starting analysis: {req.ticker} @ {req.date} via {req.llm_provider}")
        env = load_dotenv_file()
        for k, v in env.items():
            if v:
                os.environ.setdefault(k, v)

        try:
            from tradingagents.default_config import DEFAULT_CONFIG
            from tradingagents.graph.trading_graph import TradingAgentsGraph
        except Exception:
            log("FATAL: TradingAgents framework import failed — full traceback:")
            log(traceback.format_exc())
            set_state(status="error",
                      error="Framework import failed. Is /opt/tradingagents/src/TradingAgents "
                            "installed? See job log for the full traceback.")
            return

        config = DEFAULT_CONFIG.copy()
        config["llm_provider"] = req.llm_provider.lower()
        if req.deep_think_llm.strip():
            config["deep_think_llm"] = req.deep_think_llm.strip()
        if req.quick_think_llm.strip():
            config["quick_think_llm"] = req.quick_think_llm.strip()
        config["max_debate_rounds"] = req.max_debate_rounds
        config["max_risk_discuss_rounds"] = req.max_risk_rounds
        config["output_language"] = req.output_language
        if req.backend_url.strip():
            config["backend_url"] = req.backend_url.strip()
        config["checkpoint_enabled"] = req.checkpoint_enabled
        log(f"Config: provider={config['llm_provider']} "
            f"deep={config.get('deep_think_llm')} quick={config.get('quick_think_llm')} "
            f"debate={config['max_debate_rounds']} risk={config['max_risk_discuss_rounds']}")

        allowed = ("market", "social", "news", "fundamentals")
        analysts = [a for a in (req.analysts or []) if a in allowed] or list(allowed)
        log(f"Analysts: {', '.join(analysts)}")
        ta = TradingAgentsGraph(analysts, debug=True, config=config)
        log("Graph initialized, propagating ... (this can take several minutes)")
        final_state, decision = ta.propagate(req.ticker.strip().upper(), req.date.strip())
        try:
            report_path = ta.save_reports(final_state, req.ticker.strip().upper())
            log(f"Reports gespeichert: {report_path}")
        except Exception:
            log("WARN: save_reports fehlgeschlagen (Analyse trotzdem OK) — Traceback:")
            log(traceback.format_exc())
        log("Analysis complete.")
        set_state(status="done", result=str(decision))
    except Exception as exc:  # noqa: BLE001 — we persist the FULL chain
        chained = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
        log("FATAL: analysis failed — full error chain:")
        log(chained)
        set_state(status="error", error=f"{type(exc).__name__}: {exc}")


# --------------------------------------------------------------- routes ---

@app.get("/healthz")
def healthz():
    ok, detail = framework_available()
    return {"status": "ok", "framework": ok, "framework_detail": detail}


@app.get("/", response_class=HTMLResponse)
def index():
    tpl = Path(__file__).parent / "templates" / "index.html"
    return HTMLResponse(tpl.read_text(encoding="utf-8"))


@app.get("/api/config")
def get_config():
    env = load_dotenv_file()
    ok, detail = framework_available()
    deep_default = quick_default = ""
    provider_default = os.environ.get("TRADINGAGENTS_LLM_PROVIDER", env.get("TRADINGAGENTS_LLM_PROVIDER", "openai"))
    if ok:
        try:
            from tradingagents.default_config import DEFAULT_CONFIG

            deep_default = str(DEFAULT_CONFIG.get("deep_think_llm", ""))
            quick_default = str(DEFAULT_CONFIG.get("quick_think_llm", ""))
        except Exception:  # noqa: BLE001
            pass
    return {
        "framework_ok": ok,
        "framework_detail": detail,
        "llm_provider": provider_default,
        "backend_url": env.get("TRADINGAGENTS_LLM_BACKEND_URL", ""),
        "deep_think_llm": env.get("TRADINGAGENTS_DEEP_THINK_LLM", deep_default),
        "quick_think_llm": env.get("TRADINGAGENTS_QUICK_THINK_LLM", quick_default),
        "output_language": env.get("TRADINGAGENTS_OUTPUT_LANGUAGE", "English"),
        "providers": PROVIDERS,
        "keys_set": {k: bool(env.get(k)) for k in API_KEY_FIELDS},
    }


@app.post("/api/config")
def save_config(req: ConfigSaveRequest):
    if req.llm_provider.lower() not in PROVIDERS:
        raise HTTPException(status_code=400, detail=f"Unknown provider: {req.llm_provider}")
    updates: dict[str, str] = {}
    for k, v in (req.keys or {}).items():
        if k in API_KEY_FIELDS and v and v.strip() and v.strip() != "********":
            updates[k] = v.strip()
    updates["TRADINGAGENTS_LLM_PROVIDER"] = req.llm_provider.lower()
    if req.backend_url.strip():
        updates["TRADINGAGENTS_LLM_BACKEND_URL"] = req.backend_url.strip()
    if req.deep_think_llm.strip():
        updates["TRADINGAGENTS_DEEP_THINK_LLM"] = req.deep_think_llm.strip()
    if req.quick_think_llm.strip():
        updates["TRADINGAGENTS_QUICK_THINK_LLM"] = req.quick_think_llm.strip()
    if req.output_language.strip():
        updates["TRADINGAGENTS_OUTPUT_LANGUAGE"] = req.output_language.strip()
    try:
        write_dotenv_file(updates)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500,
                            detail=f"Failed to write {ENV_FILE}: {type(exc).__name__}: {exc}\n"
                                   f"{traceback.format_exc()}") from exc
    return {"saved": sorted(updates.keys())}


@app.post("/api/analyze")
def start_analysis(req: AnalyzeRequest):
    ok, detail = framework_available()
    if not ok:
        raise HTTPException(status_code=503,
                            detail=f"TradingAgents framework not importable: {detail}. "
                                   "Re-run install/install/setup-container.sh and check logs.")
    try:
        datetime.date.fromisoformat(req.date.strip())
    except ValueError:
        raise HTTPException(status_code=400, detail="date must be YYYY-MM-DD") from None
    if req.llm_provider.lower() not in PROVIDERS:
        raise HTTPException(status_code=400, detail=f"Unknown provider: {req.llm_provider}")
    job_id = uuid.uuid4().hex[:12]
    with _jobs_lock:
        _jobs[job_id] = {"status": "queued", "log": "", "result": None, "error": None,
                         "ticker": req.ticker.upper(), "date": req.date}
    t = threading.Thread(target=run_analysis_job, args=(job_id, req), daemon=True)
    t.start()
    return {"job_id": job_id}


@app.get("/api/status/{job_id}")
def job_status(job_id: str):
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="unknown job_id")
        return dict(job_id=job_id, **job)


@app.get("/api/reports")
def list_reports():
    """List generated reports under results/ and the decision memory log."""
    out: list[dict] = []
    base = Path.home() / "results"
    if base.exists():
        for f in sorted(base.rglob("*.md"))[-50:]:
            try:
                rel = str(f.relative_to(base))
            except ValueError:
                rel = str(f)
            out.append({"path": rel, "size": f.stat().st_size,
                        "mtime": datetime.datetime.fromtimestamp(
                            f.stat().st_mtime).isoformat(timespec="seconds")})
    mem = Path.home() / ".tradingagents" / "memory" / "trading_memory.md"
    return {"results_dir": str(base), "reports": out,
            "memory_log_exists": mem.exists(),
            "memory_log": str(mem)}


@app.get("/api/report")
def get_report(path: str):
    base = (Path.home() / "results").resolve()
    target = (base / path).resolve()
    if not str(target).startswith(str(base)) or not target.is_file():
        raise HTTPException(status_code=400, detail="invalid path")
    return {"path": path, "content": target.read_text(encoding="utf-8", errors="replace")}


@app.exception_handler(Exception)
async def unhandled_handler(_, exc: Exception):  # noqa: ANN001
    chained = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
    return JSONResponse(status_code=500, content={
        "error": f"{type(exc).__name__}: {exc}",
        "traceback": chained,
    })
