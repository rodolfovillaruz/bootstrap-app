#!/usr/bin/env bash
# deploy.sh — full first-time deploy in one shot
# Usage: PROJECT_ID=my-project ./deploy.sh
# Optionally override: REGION, SERVICE_NAME, ALLOWED_EMAILS

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID env var}"
REGION="${REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-bootstrap-app}"
REPO_NAME="bootstrap-repo"
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$SERVICE_NAME:latest"

# Comma-separated list of Google accounts to grant IAP access
# e.g. "user:you@example.com,group:devs@example.com"
ALLOWED_EMAILS="${ALLOWED_EMAILS:-}"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()    { echo -e "\033[1;34m▶ $*\033[0m"; }
success() { echo -e "\033[1;32m✓ $*\033[0m"; }
warn()    { echo -e "\033[1;33m⚠ $*\033[0m"; }

# ── 1. Set project ────────────────────────────────────────────────────────────
info "Setting project to $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

# ── 2. Enable APIs ────────────────────────────────────────────────────────────
info "Enabling required GCP APIs (this may take ~2 min first time)…"
gcloud services enable \
  run.googleapis.com \
  iap.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  --quiet
success "APIs enabled"

# ── 3. Artifact Registry ──────────────────────────────────────────────────────
info "Creating Artifact Registry repo '$REPO_NAME' (skip if exists)…"
gcloud artifacts repositories create "$REPO_NAME" \
  --repository-format=docker \
  --location="$REGION" \
  --quiet 2>/dev/null || true
success "Artifact Registry ready"

# ── 4. Build & push image ─────────────────────────────────────────────────────
info "Building and pushing image with Cloud Build…"
gcloud builds submit \
  --tag "$IMAGE" \
  --quiet
success "Image pushed: $IMAGE"

# ── 5. Deploy to Cloud Run ───────────────────────────────────────────────────
info "Deploying to Cloud Run ($REGION)…"
gcloud run deploy "$SERVICE_NAME" \
  --image "$IMAGE" \
  --region "$REGION" \
  --platform managed \
  --no-allow-unauthenticated \
  --min-instances 0 \
  --max-instances 2 \
  --memory 512Mi \
  --cpu 1 \
  --timeout 300 \
  --set-env-vars "PROJECT_ID=$PROJECT_ID" \
  --quiet

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --region "$REGION" \
  --format "value(status.url)")
success "Cloud Run deployed: $SERVICE_URL"

# ── 6. IAP setup ─────────────────────────────────────────────────────────────
info "Enabling IAP on Cloud Run backend…"

# Get the backend service name — Cloud Run creates one automatically
BACKEND=$(gcloud compute backend-services list \
  --filter="name~$SERVICE_NAME" \
  --format "value(name)" \
  --global 2>/dev/null | head -1 || true)

if [[ -z "$BACKEND" ]]; then
  warn "No load balancer backend found yet."
  warn "IAP requires a load balancer in front of Cloud Run."
  warn ""
  warn "Follow the manual IAP steps:"
  warn "  1. Console → Security → Identity-Aware Proxy"
  warn "  2. Enable IAP on the '$SERVICE_NAME' Cloud Run service"
  warn "  3. Add members with role 'IAP-secured Web App User'"
  warn ""
  warn "Or use a Global External HTTP(S) Load Balancer (see README)."
else
  gcloud iap web enable --resource-type=backend-services \
    --service="$BACKEND" --global --quiet
  success "IAP enabled on backend: $BACKEND"

  if [[ -n "$ALLOWED_EMAILS" ]]; then
    IFS=',' read -ra MEMBERS <<< "$ALLOWED_EMAILS"
    for MEMBER in "${MEMBERS[@]}"; do
      gcloud iap web add-iam-policy-binding \
        --resource-type=backend-services \
        --service="$BACKEND" \
        --member="$MEMBER" \
        --role="roles/iap.httpsResourceAccessor" \
        --global --quiet
      success "Granted IAP access: $MEMBER"
    done
  else
    warn "No ALLOWED_EMAILS set — grant IAP access manually in Console."
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
success "Deploy complete!"
echo ""
echo "  Service URL : $SERVICE_URL"
echo "  Health check: $SERVICE_URL/healthz"
echo ""
echo "  Next steps (if IAP not yet active):"
echo "    Console → Security → Identity-Aware Proxy"
echo "    Enable IAP on '$SERVICE_NAME' and add your email."
echo ""
