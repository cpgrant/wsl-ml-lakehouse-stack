FROM python:3.11-slim

# CA certs + curl for HTTPS and quick debug
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# <<— this is the important change
COPY . .

# OpenSSL sees the system bundle
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# Keep smoketest default
CMD ["python", "-u", "app.py"]
