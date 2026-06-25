"""
Bootstrap actions — each function here becomes a button in the UI.

To add a new action:
  1. Define an async function below
  2. Register it in ACTIONS dict at the bottom

Each action receives project_id and returns a dict with at minimum:
  {"status": "ok" | "error", "message": "..."}
"""

import asyncio
import logging
import subprocess

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Example actions — replace with your real bootstrap operations
# ---------------------------------------------------------------------------

async def action_list_buckets(project_id: str) -> dict:
    """List GCS buckets in the project."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "gcloud", "storage", "buckets", "list",
            "--project", project_id,
            "--format", "value(name)",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=30)
        if proc.returncode != 0:
            return {"status": "error", "message": stderr.decode().strip()}
        buckets = [b for b in stdout.decode().strip().splitlines() if b]
        return {"status": "ok", "message": f"Found {len(buckets)} bucket(s).", "items": buckets}
    except Exception as e:
        logger.exception("action_list_buckets failed")
        return {"status": "error", "message": str(e)}


async def action_list_run_services(project_id: str) -> dict:
    """List Cloud Run services in all regions."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "gcloud", "run", "services", "list",
            "--project", project_id,
            "--format", "table(SERVICE,REGION,URL,LAST_DEPLOYED_AT)",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=30)
        if proc.returncode != 0:
            return {"status": "error", "message": stderr.decode().strip()}
        output = stdout.decode().strip()
        return {"status": "ok", "message": output or "No services found."}
    except Exception as e:
        logger.exception("action_list_run_services failed")
        return {"status": "error", "message": str(e)}


async def action_health_check(project_id: str) -> dict:
    """Simple self-test — confirms the app is running and has project access."""
    return {
        "status": "ok",
        "message": f"Bootstrap app is healthy. Project: {project_id or '(not set)'}",
    }


# ---------------------------------------------------------------------------
# Action registry — drives the UI buttons automatically
# ---------------------------------------------------------------------------

ACTIONS: dict[str, dict] = {
    "health_check": {
        "label": "Health Check",
        "description": "Verify the app is running and has GCP project access.",
        "fn": action_health_check,
        "style": "secondary",
    },
    "list_buckets": {
        "label": "List GCS Buckets",
        "description": "Show all Cloud Storage buckets in the project.",
        "fn": action_list_buckets,
        "style": "primary",
    },
    "list_run_services": {
        "label": "List Cloud Run Services",
        "description": "Show all Cloud Run services across regions.",
        "fn": action_list_run_services,
        "style": "primary",
    },
}


def list_actions() -> list[dict]:
    return [
        {"name": name, "label": meta["label"], "description": meta["description"], "style": meta["style"]}
        for name, meta in ACTIONS.items()
    ]


async def run_action(action_name: str, project_id: str) -> dict:
    if action_name not in ACTIONS:
        return {"status": "error", "message": f"Unknown action: {action_name}"}
    fn = ACTIONS[action_name]["fn"]
    return await fn(project_id=project_id)
