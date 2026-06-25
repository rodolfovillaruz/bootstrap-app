import os
import logging
from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from bootstrap.actions import run_action, list_actions

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Bootstrap App")
templates = Jinja2Templates(directory="templates")


@app.middleware("http")
async def require_iap_header(request: Request, call_next):
    """Belt-and-suspenders IAP check. IAP already blocks unauthenticated
    requests, but this ensures no accidental bypass reaches app logic."""
    # Skip health check (Cloud Run needs this without auth)
    if request.url.path == "/healthz":
        return await call_next(request)

    user = request.headers.get("X-Goog-Authenticated-User-Email")
    if not user:
        return Response("Unauthorized — IAP required", status_code=401)

    logger.info(f"Request from {user}: {request.method} {request.url.path}")
    return await call_next(request)


@app.get("/healthz")
def health():
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    user_header = request.headers.get("X-Goog-Authenticated-User-Email", "unknown")
    # Header format: "accounts.google.com:user@example.com"
    user_email = user_header.split(":")[-1] if ":" in user_header else user_header
    project_id = os.environ.get("PROJECT_ID", "unknown")
    actions = list_actions()
    return templates.TemplateResponse("index.html", {
        "request": request,
        "user_email": user_email,
        "project_id": project_id,
        "actions": actions,
    })


@app.post("/run/{action_name}")
async def trigger_action(action_name: str, request: Request):
    user_header = request.headers.get("X-Goog-Authenticated-User-Email", "unknown")
    user_email = user_header.split(":")[-1] if ":" in user_header else user_header
    logger.info(f"Running action '{action_name}' triggered by {user_email}")
    result = await run_action(action_name, project_id=os.environ.get("PROJECT_ID", ""))
    return {"action": action_name, "triggered_by": user_email, "result": result}
