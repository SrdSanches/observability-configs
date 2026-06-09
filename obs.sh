#!/usr/bin/env bash
set -euo pipefail

# ── Configurações ─────────────────────────────────────────────────────────────

CONFIG_DIR="$(cd "$(dirname "$0")/config" && pwd)"
NETWORK="otel-net"

# ── Cores para output ─────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; }

# ── Healthcheck ───────────────────────────────────────────────────────────────

wait_for_healthy() {
  local name="$1" url="$2" retries="${3:-20}" interval="${4:-3}"
  warn "  ⏳ Aguardando $name ficar saudável..."
  for i in $(seq 1 "$retries"); do
    if curl -sf --max-time 2 "$url" > /dev/null 2>&1; then
      log "$name pronto"
      return 0
    fi
    sleep "$interval"
  done
  err "$name não respondeu após $((retries * interval))s — verifique: podman logs $name"
  return 1
}

# ── Rede ──────────────────────────────────────────────────────────────────────

create_network() {
  if ! podman network exists "$NETWORK" 2>/dev/null; then
    warn "🌐 Criando rede $NETWORK..."
    podman network create \
      --driver bridge \
      --opt com.docker.network.bridge.name=otel-br0 \
      --subnet 172.20.0.0/16 \
      --gateway 172.20.0.1 \
      --disable-dns=false \
      "$NETWORK"
    log "Rede $NETWORK criada"
  else
    warn "Rede $NETWORK já existe, reutilizando"
  fi
}

remove_network() {
  if podman network exists "$NETWORK" 2>/dev/null; then
    podman network rm "$NETWORK" 2>/dev/null || true
    log "Rede $NETWORK removida"
  fi
}

# ── Subir serviços ────────────────────────────────────────────────────────────

start_tempo() {
  warn "🔷 Subindo Grafana Tempo..."
  podman run -d \
    --name tempo \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 3200:3200 \
    -v "$CONFIG_DIR/tempo.yaml:/etc/tempo/config.yaml:ro" \
    docker.io/grafana/tempo:latest \
    -config.file=/etc/tempo/config.yaml
}

start_prometheus() {
  warn "🔶 Subindo Prometheus..."
  podman run -d \
    --name prometheus \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 9090:9090 \
    -v "$CONFIG_DIR/prometheus.yaml:/etc/prometheus/prometheus.yaml:ro" \
    docker.io/prom/prometheus:latest \
    --config.file=/etc/prometheus/prometheus.yaml \
    --web.enable-remote-write-receiver \
    --web.enable-otlp-receiver \
    --enable-feature=exemplar-storage \
    --enable-feature=otlp-write-receiver
}

start_loki() {
  warn "🟠 Subindo Grafana Loki..."
  podman run -d \
    --name loki \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 3100:3100 \
    -v "$CONFIG_DIR/loki.yaml:/etc/loki/config.yaml:ro" \
    docker.io/grafana/loki:latest \
    -config.file=/etc/loki/config.yaml
}

start_collector() {
  warn "🟣 Subindo OTel Collector..."
  podman run -d \
    --name otel-collector \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 4317:4317 \
    -p 4318:4318 \
    -p 8888:8888 \
    -p 13133:13133 \
    -v "$CONFIG_DIR/otel-collector.yaml:/etc/otel/config.yaml:ro" \
    docker.io/otel/opentelemetry-collector-contrib:latest \
    --config=/etc/otel/config.yaml
}

start_grafana() {
  warn "🟡 Subindo Grafana..."
  podman run -d \
    --name grafana \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 3001:3000 \
    -e GF_AUTH_ANONYMOUS_ENABLED=true \
    -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
    -e GF_AUTH_DISABLE_LOGIN_FORM=true \
    -v "$CONFIG_DIR/grafana/provisioning:/etc/grafana/provisioning:ro" \
    docker.io/grafana/grafana:latest
}

# ── Up ────────────────────────────────────────────────────────────────────────

up() {
  log  "🚀 Subindo ambiente de observabilidade..."
  echo ""

  create_network

  start_tempo
  wait_for_healthy "Tempo"          "http://localhost:3200/ready"

  start_prometheus
  wait_for_healthy "Prometheus"     "http://localhost:9090/-/ready"

  start_loki
  wait_for_healthy "Loki"           "http://localhost:3100/ready"

  start_collector
  wait_for_healthy "OTel Collector" "http://localhost:13133/ready"

  start_grafana
  wait_for_healthy "Grafana"        "http://localhost:3001/api/health"

  echo ""
  log  "══════════════════════════════════════════════════════════════"
  log  "Ambiente pronto!"
  echo ""
  log  "  Grafana      → http://localhost:3001"
  log  "  Prometheus   → http://localhost:9090"
  log  "  Loki API     → http://localhost:3100"
  log  "  Tempo API    → http://localhost:3200"
  log  "  OTel gRPC    → localhost:4317  ← microsserviços apontam aqui"
  log  "══════════════════════════════════════════════════════════════"
  echo ""
}

# ── Down ──────────────────────────────────────────────────────────────────────

down() {
  warn "🛑 Derrubando ambiente..."
  echo ""

  for container in grafana otel-collector loki prometheus tempo; do
    if podman container exists "$container" 2>/dev/null; then
      warn "  Removendo $container..."
      podman rm -f "$container" 2>/dev/null || true
    fi
  done

  remove_network

  echo ""
  log "Ambiente encerrado!"
}

# ── Logs ──────────────────────────────────────────────────────────────────────

logs() {
  local valid_services="tempo prometheus loki otel-collector grafana"
  local service="${1:-}"

  if [ -z "$service" ]; then
    warn "Nenhum serviço especificado. Disponíveis: $valid_services"
    echo "Uso: $0 logs {tempo|prometheus|loki|otel-collector|grafana}"
    exit 1
  fi

  if ! echo "$valid_services" | grep -qw "$service"; then
    err "Serviço desconhecido: '$service'. Disponíveis: $valid_services"
    exit 1
  fi

  if ! podman container exists "$service" 2>/dev/null; then
    err "Container '$service' não está rodando. Execute: $0 up"
    exit 1
  fi

  podman logs -f "$service"
}

# ── Status ────────────────────────────────────────────────────────────────────

status() {
  log  "📊 Status dos containers:"
  echo ""
  podman ps \
    --filter "name=tempo" \
    --filter "name=prometheus" \
    --filter "name=loki" \
    --filter "name=otel-collector" \
    --filter "name=grafana" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# ── Restart ───────────────────────────────────────────────────────────────────

restart() {
  down
  sleep 2
  up
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

case "${1:-up}" in
  up)      up ;;
  down)    down ;;
  restart) restart ;;
  logs)    logs "${2:-}" ;;
  status)  status ;;
  *)
    echo "Uso: $0 {up|down|restart|logs <serviço>|status}"
    exit 1
    ;;
esac
