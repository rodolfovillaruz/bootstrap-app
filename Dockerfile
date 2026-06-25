# Pin the tag — never use :latest in production
FROM python:3.12-slim

# Security: run as non-root
RUN useradd --create-home appuser
WORKDIR /app

# Deps first for better layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App source
COPY --chown=appuser:appuser . .

USER appuser

# Cloud Run injects PORT; default 8080
ENV PORT=8080
EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
