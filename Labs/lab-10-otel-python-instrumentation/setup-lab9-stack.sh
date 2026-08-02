#!/usr/bin/env bash
# setup-lab9-stack.sh
# Brings up the same Grafana + Tempo stack that Lab 9 uses, so Lab 10
# can run as a self-contained exercise. Idempotent: safe to re-run.

set -euo pipefail

# 0. Make sure python3-venv is available. On a fresh Debian/Ubuntu
#    container, ensurepip is missing and `python3 -m venv` errors out
#    with "externally-managed-environment". Install the metapackage,
#    falling back to the versioned variant if the metapackage is
#    unavailable.
if ! python3 -m venv --help >/dev/null 2>&1; then
  echo "Installing python3-venv..."
  sudo apt-get update
  if ! sudo apt-get install -y python3-venv python3-pip; then
    PYV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    echo "Trying python${PYV}-venv instead..."
    sudo apt-get install -y "python${PYV}-venv" python3-pip
  fi
fi

# 1. Pick the project directory (defaults to the script's own folder).
PROJECT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "$PROJECT_DIR"

mkdir -p grafana/provisioning/datasources

# 2. Compose stack — Tempo on 3200/4318, Grafana on 3001.
cat > docker-compose.yml <<'EOF'
services:
  tempo:
    image: grafana/tempo:latest
    command: ["-config.file=/etc/tempo.yml"]
    volumes:
      - ./tempo.yml:/etc/tempo.yml:ro
      - tempo-data:/var/tempo
    ports:
      - "3200:3200"
      - "4318:4318"

  grafana:
    image: grafana/grafana:latest
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    ports:
      - "3001:3000"
    depends_on:
      - tempo

volumes:
  tempo-data:
EOF

# 3. Tempo config — opens the OTLP HTTP receiver on 0.0.0.0:4318.
cat > tempo.yml <<'EOF'
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        http:
          endpoint: 0.0.0.0:4318

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/traces
    wal:
      path: /var/tempo/wal
EOF

# 4. Grafana provisioning — Tempo datasource via the docker service name.
cat > grafana/provisioning/datasources/tempo.yaml <<'EOF'
apiVersion: 1

datasources:
  - name: Tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    isDefault: true
    editable: true
EOF

# 5. Bring the stack up.
docker compose up -d
docker compose ps

# 6. Health check.
echo "Tempo  ready? $(curl -s -o /dev/null -w '%{http_code}' http://localhost:3200/ready)"
echo "Grafana ready? $(curl -s -o /dev/null -w '%{http_code}' http://localhost:3001/api/health)"

echo
echo "Stack is up. Container ports bound:"
echo "  3001 -> Grafana UI (admin / admin)"
echo "  3200 -> Tempo query API"
echo "  4318 -> Tempo OTLP HTTP receiver"
echo
echo "Next: open the Load Balancer modal and expose 4318, 3200, and 3001 on LB_IP"
echo "      (the first IP from 'hostname -I')."
