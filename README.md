# Bootstrap App

Zero-idle-cost GCP ops dashboard. Runs on Cloud Run + Google IAP.
Costs $0/month when not in use. Login is your Google account — no passwords.

---

## First deploy (one command)

```bash
# Set your project ID, then run the script
PROJECT_ID=my-gcp-project ./deploy.sh

# Optional overrides:
PROJECT_ID=my-project \
REGION=europe-west1 \
ALLOWED_EMAILS="user:you@example.com" \
./deploy.sh
```

The script handles: API enablement, Artifact Registry, Cloud Build, Cloud Run deploy.
IAP may need a manual step — see the script output.

---

## IAP manual setup (if deploy.sh can't do it automatically)

Cloud Run IAP requires a Global External Load Balancer. The console route is easiest:

1. **Console → Security → Identity-Aware Proxy**
2. Click **Enable API** if prompted
3. Find your Cloud Run service under "HTTPS Resources"
4. Toggle IAP **On**
5. Click **Add Principal** → your email → role **IAP-secured Web App User**

After enabling, visiting the Cloud Run URL redirects to Google login automatically.

---

## Adding new bootstrap actions

Edit `bootstrap/actions.py`:

```python
async def action_my_thing(project_id: str) -> dict:
    """Description shown in the UI."""
    # ... your logic
    return {"status": "ok", "message": "Done!"}

# Register it in ACTIONS dict:
ACTIONS["my_thing"] = {
    "label": "My Thing",
    "description": "Does the thing.",
    "fn": action_my_thing,
    "style": "primary",   # or "secondary"
}
```

Then redeploy:
```bash
PROJECT_ID=my-gcp-project ./deploy.sh
```

---

## Secrets (API keys, credentials)

Never put secrets in code or env vars. Use Secret Manager:

```bash
# Store
echo -n "my-api-key" | gcloud secrets create MY_API_KEY \
  --data-file=- --project=my-gcp-project

# Grant Cloud Run SA access
SA=$(gcloud run services describe bootstrap-app \
  --region us-central1 \
  --format "value(spec.template.spec.serviceAccountName)")

gcloud secrets add-iam-policy-binding MY_API_KEY \
  --member="serviceAccount:$SA" \
  --role="roles/secretmanager.secretAccessor"
```

Read in code:
```python
from google.cloud import secretmanager

client = secretmanager.SecretManagerServiceClient()
name = f"projects/{project_id}/secrets/MY_API_KEY/versions/latest"
payload = client.access_secret_version(name=name).payload.data.decode()
```

---

## Redeploy after code changes

```bash
PROJECT_ID=my-gcp-project ./deploy.sh
```

That's it. Cloud Build rebuilds the image and Cloud Run does a zero-downtime rollout.

## Rollback

```bash
# List revisions
gcloud run revisions list --service bootstrap-app --region us-central1

# Route 100% traffic to a previous revision
gcloud run services update-traffic bootstrap-app \
  --region us-central1 \
  --to-revisions REVISION_NAME=100
```

---

## Custom domain (keep URL stable forever)

```bash
gcloud run domain-mappings create \
  --service bootstrap-app \
  --domain bootstrap.yourdomain.com \
  --region us-central1
```

Add the DNS records it outputs to your DNS provider. Done.

---

## Cost

| When | Cost |
|------|------|
| Idle (no requests) | $0/month |
| Light use (<100 runs/month) | ~$0/month (free tier) |
| Heavy use (1000+ runs/month) | ~$1–2/month |

Set a billing alert: **Console → Billing → Budgets & Alerts → $10 threshold**

---

## Longevity checklist

- [x] Dockerfile pins `python:3.12-slim` — not `latest`
- [x] Image stored in Artifact Registry — not Docker Hub
- [x] `--min-instances 0` — true scale-to-zero
- [ ] Set billing alert at $10/month
- [ ] Enable custom domain mapping
- [ ] Store secrets in Secret Manager (not env vars)
- [ ] Document the redeploy command above in your wiki

---

## File structure

```
bootstrap-app/
├── main.py              # FastAPI app + IAP middleware
├── bootstrap/
│   └── actions.py       # Your operations — edit this
├── templates/
│   └── index.html       # Web UI
├── requirements.txt
├── Dockerfile
├── deploy.sh            # First-time + subsequent deploys
└── README.md
```
