FROM python:3.11-slim

# Install CA certs (needed for HTTPS) and curl (for quick debug)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# Make sure OpenSSL sees the system bundle
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

CMD ["python", "-u", "app.py"]
