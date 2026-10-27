#!/usr/bin/env bash
# 產生自簽 HTTPS 憑證。手機瀏覽器只允許在 HTTPS 頁面開相機。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout certs/key.pem -out certs/cert.pem -subj "/CN=jetson-cam" \
  -addext "subjectAltName=IP:10.42.0.1,IP:127.0.0.1,DNS:localhost"
echo "已產生 jetson/certs/cert.pem 與 key.pem"
