import os
import logging
import firebase_admin
from firebase_admin import auth as firebase_auth
from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired
from bootstrap.actions import run_action, list_actions

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

firebase_admin.initialize_app()

app = FastAPI(title="Bootstrap App")
templates = Jinja2Templates(directory="templates")

SECRET_KEY = os.environ["SECRET_KEY"]
SESSION_MAX_AGE = 60 * 60 * 8  # 8 hours
_signer = URLSafeTimedSerializer(SECRET_KEY, salt="session")

ALLOWED_DOMAIN = os.environ.get("ALLOWED_DOMAIN", "")


def _get_session(request: Request) -> str | None:
    token = request.cookies.get("session")
    if not token:
        return None
    try:
        return _signer.loads(token, max_age=SESSION_MAX_AGE)
    except (BadSignature, SignatureExpired):
        return None


def _set_session(response: Response, email: str) -> None:
    token = _signer.dumps(email)
    response.set_cookie(
        "session", token,
        httponly=True, secure=True, samesite="lax",
        max_age=SESSION_MAX_AGE,
    )


@app.get("/healthz")
def health():
    return {"status": "ok"}


FIREBASE_CONFIG = {
    "apiKey": os.environ["FIREBASE_API_KEY"],
    "authDomain": os.environ["FIREBASE_AUTH_DOMAIN"],
    "projectId": os.environ.get("PROJECT_ID", ""),
}


@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    if _get_session(request):
        return RedirectResponse("/")
    return templates.TemplateResponse("login.html", {
        "request": request,
        "firebase_config": FIREBASE_CONFIG,
    })


@app.post("/auth/verify")
async def verify_token(request: Request):
    body = await request.json()
    id_token = body.get("idToken", "")
    try:
        decoded = firebase_auth.verify_id_token(id_token)
    except Exception as e:
        logger.warning(f"Token verification failed: {e}")
        return JSONResponse({"error": "invalid token"}, status_code=401)

    email = decoded.get("email", "")
    if ALLOWED_DOMAIN and not email.endswith(f"@{ALLOWED_DOMAIN}"):
        logger.warning(f"Rejected login from {email} (not in allowed domain)")
        return JSONResponse({"error": "email domain not allowed"}, status_code=403)

    logger.info(f"Authenticated: {email}")
    response = JSONResponse({"ok": True})
    _set_session(response, email)
    return response


@app.get("/logout")
async def logout():
    response = RedirectResponse("/login")
    response.delete_cookie("session")
    return response


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    email = _get_session(request)
    if not email:
        return RedirectResponse("/login")
    project_id = os.environ.get("PROJECT_ID", "unknown")
    actions = list_actions()
    return templates.TemplateResponse("index.html", {
        "request": request,
        "user_email": email,
        "project_id": project_id,
        "actions": actions,
    })


@app.post("/run/{action_name}")
async def trigger_action(action_name: str, request: Request):
    email = _get_session(request)
    if not email:
        return JSONResponse({"error": "unauthenticated"}, status_code=401)
    logger.info(f"Running action '{action_name}' triggered by {email}")
    result = await run_action(action_name, project_id=os.environ.get("PROJECT_ID", ""))
    return {"action": action_name, "triggered_by": email, "result": result}
