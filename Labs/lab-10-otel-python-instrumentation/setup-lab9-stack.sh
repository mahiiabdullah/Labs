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

# 0b. Pick host ports that are not already in use. Poridhi lab containers
#     occasionally leave a previous Grafana/Tempo stack bound to the
#     default ports (3000/3200/4318), which makes "port is already
#     allocated" fail the new container. Probe each candidate and fall
#     back to the first free port above it.
pick_port () {
  local base=$1
  local p=$base
  while [ "$p" -lt $((base + 100)) ]; do
    if ! (echo > "/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
    p=$((p + 1))
  done
  echo "$base"
}

TEMPO_OTLP_PORT=$(pick_port 4318)
TEMPO_QUERY_PORT=$(pick_port 3200)
GRAFANA_PORT=$(pick_port 3000)
export TEMPO_OTLP_PORT TEMPO_QUERY_PORT GRAFANA_PORT

echo "Using host ports: Tempo OTLP=$TEMPO_OTLP_PORT  Tempo query=$TEMPO_QUERY_PORT  Grafana=$GRAFANA_PORT"

# 1. Pick the project directory (defaults to the script's own folder).
PROJECT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "$PROJECT_DIR"

mkdir -p grafana/provisioning/datasources

# 2. Compose stack. The chosen host ports are written in literally.
cat > docker-compose.yml <<EOF
services:
  tempo:
    image: grafana/tempo:latest
    command: ["-config.file=/etc/tempo.yml"]
    volumes:
      - ./tempo.yml:/etc/tempo.yml:ro
      - tempo-data:/var/tempo
    ports:
      - "${TEMPO_QUERY_PORT}:3200"
      - "${TEMPO_OTLP_PORT}:4318"

  grafana:
    image: grafana/grafana:latest
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    ports:
      - "${GRAFANA_PORT}:3000"
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

# 6. Health check (against the host ports we actually bound).
echo "Tempo  ready? $(curl -s -o /dev/null -w '%{http_code}' http://localhost:${TEMPO_QUERY_PORT}/ready)"
echo "Grafana ready? $(curl -s -o /dev/null -w '%{http_code}' http://localhost:${GRAFANA_PORT}/api/health)"

# 7. Persist the chosen ports so the caller (lab README) can pick them up
#    without re-running the probe.
cat > .stack-ports <<EOF
TEMPO_OTLP_PORT=${TEMPO_OTLP_PORT}
TEMPO_QUERY_PORT=${TEMPO_QUERY_PORT}
GRAFANA_PORT=${GRAFANA_PORT}
EOF

echo
echo "Stack is up. Container ports bound (host -> container):"
echo "  ${GRAFANA_PORT} -> Grafana UI (admin / admin)"
echo "  ${TEMPO_QUERY_PORT} -> Tempo query API"
echo "  ${TEMPO_OTLP_PORT} -> Tempo OTLP HTTP receiver"
echo
echo "The chosen ports are saved in .stack-ports for later steps."
echo "Next: open the Load Balancer modal and expose ${TEMPO_OTLP_PORT}, ${TEMPO_QUERY_PORT}, and ${GRAFANA_PORT} on LB_IP"
echo "      (the first IP from 'hostname -I')."
