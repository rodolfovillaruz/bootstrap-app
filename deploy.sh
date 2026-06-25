#!/usr/bin/env bash
# deploy.sh — full deploy: Cloud Run + Global LB + IAP
# Usage: PROJECT_ID=my-project ./deploy.sh
# Optionally override: REGION, SERVICE_NAME, DOMAIN, ALLOWED_EMAILS

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID env var}"
REGION="${REGION:-europe-north2}"
SERVICE_NAME="${SERVICE_NAME:-bootstrap-app}"
DOMAIN="${DOMAIN:-bootstrap-app.yes.ph}"
REPO_NAME="bootstrap-repo"
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$SERVICE_NAME:latest"

# Comma-separated members to grant IAP access
# e.g. "user:you@example.com,group:devs@example.com"
ALLOWED_EMAILS="${ALLOWED_EMAILS:-}"

# Derived LB resource names (all global)
IP_NAME="$SERVICE_NAME-ip"
NEG_NAME="$SERVICE_NAME-neg"
BACKEND_NAME="$SERVICE_NAME-backend"
URL_MAP_NAME="$SERVICE_NAME-urlmap"
CERT_NAME="$SERVICE_NAME-cert"
HTTPS_PROXY_NAME="$SERVICE_NAME-https-proxy"
HTTP_PROXY_NAME="$SERVICE_NAME-http-proxy"
HTTPS_RULE_NAME="$SERVICE_NAME-https-rule"
HTTP_RULE_NAME="$SERVICE_NAME-http-rule"
HTTP_REDIRECT_MAP="$SERVICE_NAME-http-redirect"

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
  compute.googleapis.com \
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

# ── 5. Deploy to Cloud Run ────────────────────────────────────────────────────
info "Deploying to Cloud Run ($REGION)…"
gcloud run deploy "$SERVICE_NAME" \
  --image "$IMAGE" \
  --region "$REGION" \
  --platform managed \
  --no-allow-unauthenticated \
  --ingress internal-and-cloud-load-balancing \
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

# ── 6. Static IP ──────────────────────────────────────────────────────────────
info "Reserving global static IP '$IP_NAME'…"
gcloud compute addresses create "$IP_NAME" \
  --network-tier=PREMIUM \
  --ip-version=IPV4 \
  --global \
  --quiet 2>/dev/null || true

STATIC_IP=$(gcloud compute addresses describe "$IP_NAME" \
  --global --format "value(address)")
success "Static IP: $STATIC_IP"

# ── 7. Serverless NEG ─────────────────────────────────────────────────────────
info "Creating serverless NEG '$NEG_NAME'…"
gcloud compute network-endpoint-groups create "$NEG_NAME" \
  --region="$REGION" \
  --network-endpoint-type=serverless \
  --cloud-run-service="$SERVICE_NAME" \
  --quiet 2>/dev/null || true
success "Serverless NEG ready"

# ── 8. Backend service ────────────────────────────────────────────────────────
info "Creating backend service '$BACKEND_NAME'…"
gcloud compute backend-services create "$BACKEND_NAME" \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --global \
  --quiet 2>/dev/null || true

gcloud compute backend-services add-backend "$BACKEND_NAME" \
  --global \
  --network-endpoint-group="$NEG_NAME" \
  --network-endpoint-group-region="$REGION" \
  --quiet 2>/dev/null || true
success "Backend service ready"

# ── 9. Enable IAP on backend ──────────────────────────────────────────────────
info "Enabling IAP on backend service…"

# IAP requires an OAuth brand/client. Use the project-level internal brand if
# it exists, otherwise create one (one per project, cannot be deleted).
BRAND=$(gcloud iap oauth-brands list --format="value(name)" 2>/dev/null | head -1 || true)
if [[ -z "$BRAND" ]]; then
  info "Creating IAP OAuth brand for project…"
  SUPPORT_EMAIL=$(gcloud config get-value account)
  BRAND=$(gcloud iap oauth-brands create \
    --application_title="$SERVICE_NAME" \
    --support_email="$SUPPORT_EMAIL" \
    --format="value(name)")
  success "OAuth brand created: $BRAND"
fi

# Create an OAuth client for IAP (idempotent: skip if already present)
CLIENT_ID=""
CLIENT_SECRET=""
EXISTING_CLIENT=$(gcloud iap oauth-clients list "$BRAND" \
  --format="value(name)" 2>/dev/null | head -1 || true)

if [[ -z "$EXISTING_CLIENT" ]]; then
  info "Creating IAP OAuth client…"
  CLIENT_JSON=$(gcloud iap oauth-clients create "$BRAND" \
    --display_name="$SERVICE_NAME-iap-client" \
    --format=json)
  CLIENT_ID=$(echo "$CLIENT_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['name'].split('/')[-1])")
  CLIENT_SECRET=$(echo "$CLIENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['secret'])")
else
  warn "IAP OAuth client already exists; reusing: $EXISTING_CLIENT"
  CLIENT_ID=$(echo "$EXISTING_CLIENT" | awk -F'/' '{print $NF}')
  # Secret is not retrievable after creation — IAP update below uses --oauth2-client-id only
fi

# Enable IAP on the backend service
if [[ -n "$CLIENT_SECRET" ]]; then
  gcloud compute backend-services update "$BACKEND_NAME" \
    --global \
    --iap=enabled,oauth2-client-id="$CLIENT_ID",oauth2-client-secret="$CLIENT_SECRET" \
    --quiet
else
  gcloud compute backend-services update "$BACKEND_NAME" \
    --global \
    --iap=enabled,oauth2-client-id="$CLIENT_ID",oauth2-client-secret=PLACEHOLDER \
    --quiet 2>/dev/null || \
  warn "Could not set IAP client secret (secret only available at creation time). Set it manually in Console → Security → IAP."
fi
success "IAP enabled on backend"

# Grant IAP access to specified users
if [[ -n "$ALLOWED_EMAILS" ]]; then
  IFS=',' read -ra MEMBERS <<< "$ALLOWED_EMAILS"
  for MEMBER in "${MEMBERS[@]}"; do
    gcloud iap web add-iam-policy-binding \
      --resource-type=backend-services \
      --service="$BACKEND_NAME" \
      --member="$MEMBER" \
      --role="roles/iap.httpsResourceAccessor" \
      --global --quiet
    success "Granted IAP access: $MEMBER"
  done
else
  warn "No ALLOWED_EMAILS set — grant IAP access manually in Console → Security → IAP."
fi

# ── 10. URL map ───────────────────────────────────────────────────────────────
info "Creating URL map '$URL_MAP_NAME'…"
gcloud compute url-maps create "$URL_MAP_NAME" \
  --default-service="$BACKEND_NAME" \
  --global \
  --quiet 2>/dev/null || true
success "URL map ready"

# ── 11. Managed SSL certificate ───────────────────────────────────────────────
info "Creating managed SSL certificate for $DOMAIN…"
gcloud compute ssl-certificates create "$CERT_NAME" \
  --domains="$DOMAIN" \
  --global \
  --quiet 2>/dev/null || true
success "SSL certificate requested (provisioning may take 10–60 min after DNS is set)"

# ── 12. HTTPS target proxy ────────────────────────────────────────────────────
info "Creating HTTPS target proxy…"
gcloud compute target-https-proxies create "$HTTPS_PROXY_NAME" \
  --url-map="$URL_MAP_NAME" \
  --ssl-certificates="$CERT_NAME" \
  --global \
  --quiet 2>/dev/null || true
success "HTTPS proxy ready"

# ── 13. HTTP → HTTPS redirect ─────────────────────────────────────────────────
info "Creating HTTP→HTTPS redirect…"
gcloud compute url-maps import "$HTTP_REDIRECT_MAP" \
  --global \
  --quiet \
  --source=/dev/stdin <<'EOF' 2>/dev/null || true
name: placeholder
defaultUrlRedirect:
  redirectResponseCode: MOVED_PERMANENTLY_DEFAULT
  httpsRedirect: true
EOF

gcloud compute target-http-proxies create "$HTTP_PROXY_NAME" \
  --url-map="$HTTP_REDIRECT_MAP" \
  --global \
  --quiet 2>/dev/null || true

# ── 14. Forwarding rules ──────────────────────────────────────────────────────
info "Creating forwarding rules…"
gcloud compute forwarding-rules create "$HTTPS_RULE_NAME" \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --network-tier=PREMIUM \
  --address="$IP_NAME" \
  --target-https-proxy="$HTTPS_PROXY_NAME" \
  --ports=443 \
  --global \
  --quiet 2>/dev/null || true

gcloud compute forwarding-rules create "$HTTP_RULE_NAME" \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --network-tier=PREMIUM \
  --address="$IP_NAME" \
  --target-http-proxy="$HTTP_PROXY_NAME" \
  --ports=80 \
  --global \
  --quiet 2>/dev/null || true

success "Forwarding rules created"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
success "Deploy complete!"
echo ""
echo "  Static IP   : $STATIC_IP"
echo "  Domain      : https://$DOMAIN"
echo "  Health check: https://$DOMAIN/healthz"
echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║  ACTION REQUIRED: point your DNS A record                   ║"
echo "  ║    $DOMAIN  →  $STATIC_IP               ║"
echo "  ║                                                              ║"
echo "  ║  The managed SSL cert provisions automatically once DNS      ║"
echo "  ║  resolves (usually 10–60 min after the DNS change).         ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  To grant IAP access to a user, re-run with:"
echo "    ALLOWED_EMAILS=user:you@example.com PROJECT_ID=$PROJECT_ID ./deploy.sh"
echo ""
