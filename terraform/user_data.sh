#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

# ─── SYSTEM ──────────────────────────────────────────────────────────────────
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# ─── DEPENDENCIES ────────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y \
  apt-transport-https ca-certificates curl \
  software-properties-common awscli git jq

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# ─── ECR LOGIN ───────────────────────────────────────────────────────────────
# IAM instance profile provides credentials - no aws configure needed
aws ecr get-login-password --region ${region} | \
  docker login --username AWS --password-stdin ${ecr_registry}

# ─── FETCH DB CREDENTIALS FROM SECRETS MANAGER ───────────────────────────────
# Instance profile gives us permission - no hardcoded keys
echo "Polling Secrets Manager for active RDS credentials..."
for i in {1..70}; do
  SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "${secret_name}" \
    --region "${region}" \
    --query SecretString \
    --output text 2>/dev/null) && break
  echo "Secret staging value not populated yet (Attempt $i/30). Retrying in 20s..."
  sleep 20
done

if [ -z "$${SECRET_JSON:-}" ]; then
  echo "CRITICAL: Database initialization payload timed out." >&2
  exit 1
fi

DB_HOST=$(echo "$SECRET_JSON" | jq -r '.host')
DB_USER=$(echo "$SECRET_JSON" | jq -r '.username')
DB_PASS=$(echo "$SECRET_JSON" | jq -r '.password')
DB_NAME=$(echo "$SECRET_JSON" | jq -r '.dbname')
DB_PORT=$(echo "$SECRET_JSON" | jq -r '.port')

docker pull ${image_uri}

# ─── VERIFY IMAGE SIGNATURE BEFORE RUNNING ───────────────────────────────────
COSIGN_VERSION="v2.4.1"
curl -sSL -o /usr/local/bin/cosign \
  "https://github.com/sigstore/cosign/releases/download/$${COSIGN_VERSION}/cosign-linux-amd64"
chmod +x /usr/local/bin/cosign

cosign verify \
  --certificate-identity "https://github.com/Re4lLife/app-devsecops/.github/workflows/app-pipeline.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ${image_uri} || { echo "Signature verification FAILED — refusing to deploy"; exit 1; }

# ─── RUN APP CONTAINER ───────────────────────────────────────────────────────
docker run -d \
  -p ${container_port}:3000 \
  --name app \
  --restart unless-stopped \
  -e DB_HOST="$DB_HOST" \
  -e DB_USER="$DB_USER" \
  -e DB_PASSWORD="$DB_PASS" \
  -e DB_NAME="$DB_NAME" \
  -e DB_PORT="$DB_PORT" \
  -e PORT="3000" \
  ${image_uri}

# ─── WAZUH ───────────────────────────────────────────────────────────────────
git clone https://github.com/wazuh/wazuh-docker.git /opt/wazuh-docker
cd /opt/wazuh-docker
git checkout v4.14.5
cd single-node

docker compose -f generate-indexer-certs.yml run --rm generator
docker compose up -d

# ─── WAZUH AGENT ─────────────────────────────────────────────────────────────
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
  gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
  https://packages.wazuh.com/4.x/apt/ stable main" \
  | tee /etc/apt/sources.list.d/wazuh.list

apt-get update -y
WAZUH_MANAGER="127.0.0.1" apt-get install -y wazuh-agent

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent