#!/usr/bin/env bash
#
# ReplayIQ fully-native dev runner: Postgres, MinIO, Ollama, Redpanda (Kafka),
# and the four decoupled Go services + dashboard — all as plain host processes.
#
#   ./dev.sh up       Install/provision native infra if needed, then start
#                     everything (minio, ollama, redpanda, ingest, processor,
#                     query, gateway, dashboard).
#   ./dev.sh down     Stop the processes this script started.
#   ./dev.sh status   Show what's currently running.
#   ./dev.sh logs [ingest|processor|query|gateway|dashboard|minio|ollama|kafka]
#                     Tail logs for a specific service (or all).
#   ./dev.sh build    Rebuild all Go binaries without restarting.
#
# For a fully containerized stack instead, ignore this script and run:
#   docker compose up -d
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ -f .env ]; then
  set -a; source .env; set +a
fi

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-replayiq_secret}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.1:8b}"
EMBEDDING_MODEL="nomic-embed-text"
KAFKA_BROKERS="${KAFKA_BROKERS:-localhost:9092}"

DATABASE_URL="postgres://replayiq:${POSTGRES_PASSWORD}@localhost:5432/replayiq?sslmode=disable"

RUN_DIR="$(pwd)/.dev"
mkdir -p "$RUN_DIR"

is_up() {
  [ -f "$RUN_DIR/$1.pid" ] && kill -0 "$(cat "$RUN_DIR/$1.pid" 2>/dev/null)" 2>/dev/null
}

require_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required. Install it from https://brew.sh and re-run." >&2
    exit 1
  fi
}

# ─── Postgres: use the existing native install ──────────────────────────────
ensure_postgres() {
  if ! command -v psql >/dev/null 2>&1; then
    require_brew
    echo "==> No native Postgres found, installing postgresql@15 via Homebrew..."
    brew install postgresql@15
    brew services start postgresql@15
  fi

  if ! pg_isready -q 2>/dev/null; then
    echo "==> Native Postgres isn't running. Start it yourself (e.g. 'brew services start postgresql@15') and re-run." >&2
    exit 1
  fi

  local pg_config pg_version
  pg_config="$(command -v pg_config)"
  pg_version="$("$pg_config" --version | awk '{print $2}' | cut -d. -f1)"

  if [ ! -f "$("$pg_config" --pkglibdir)/vector.so" ]; then
    require_brew
    if brew list pgvector >/dev/null 2>&1 && [ ! -f "$("$pg_config" --pkglibdir)/vector.so" ]; then
      echo "==> pgvector is installed via Homebrew but not built for Postgres $pg_version - building from source..."
    else
      echo "==> Installing pgvector for Postgres $pg_version (building from source)..."
    fi
    local src_dir="$RUN_DIR/pgvector-src"
    if [ ! -d "$src_dir" ]; then
      git clone --depth 1 https://github.com/pgvector/pgvector.git "$src_dir"
    fi
    make -C "$src_dir" PG_CONFIG="$pg_config"
    make -C "$src_dir" install PG_CONFIG="$pg_config"
  fi

  if ! psql -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='replayiq'" 2>/dev/null | grep -q 1; then
    echo "==> Creating 'replayiq' Postgres role..."
    psql -d postgres -c "CREATE ROLE replayiq WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}' CREATEDB;"
  fi

  if ! psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='replayiq'" 2>/dev/null | grep -q 1; then
    echo "==> Creating 'replayiq' database..."
    psql -d postgres -c "CREATE DATABASE replayiq OWNER replayiq;"
  fi

  psql -d replayiq -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null
}

# ─── MinIO ───────────────────────────────────────────────────────────────────
ensure_minio_installed() {
  if ! command -v minio >/dev/null 2>&1; then
    require_brew
    echo "==> Installing MinIO via Homebrew..."
    brew install minio
  fi
}

start_minio() {
  if is_up minio; then
    echo "MinIO already running (pid $(cat "$RUN_DIR/minio.pid"))."
    return
  fi
  if curl -sf http://localhost:9000/minio/health/live >/dev/null 2>&1; then
    echo "MinIO already reachable on :9000 (not started by this script)."
    return
  fi
  echo "==> Starting MinIO on :9000 (console :9001)..."
  mkdir -p "$RUN_DIR/minio-data"
  MINIO_ROOT_USER="${MINIO_ACCESS_KEY}" MINIO_ROOT_PASSWORD="${MINIO_SECRET_KEY}" \
    nohup minio server "$RUN_DIR/minio-data" --address ":9000" --console-address ":9001" \
    > "$RUN_DIR/minio.log" 2>&1 &
  echo $! > "$RUN_DIR/minio.pid"
  for _ in $(seq 1 30); do
    curl -sf http://localhost:9000/minio/health/live >/dev/null 2>&1 && return
    sleep 1
  done
  echo "MinIO didn't become healthy — check .dev/minio.log" >&2
  exit 1
}

# ─── Ollama ──────────────────────────────────────────────────────────────────
ensure_ollama() {
  if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "Ollama already reachable on :11434 (using existing instance)."
  else
    if ! command -v ollama >/dev/null 2>&1; then
      echo "==> ollama not found. Install it from https://ollama.ai and re-run." >&2
      exit 1
    fi
    echo "==> Starting ollama serve..."
    nohup ollama serve > "$RUN_DIR/ollama.log" 2>&1 &
    echo $! > "$RUN_DIR/ollama.pid"
    for _ in $(seq 1 30); do
      curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 && break
      sleep 1
    done
  fi

  for model in "$OLLAMA_MODEL" "$EMBEDDING_MODEL"; do
    local want="$model"
    case "$want" in *:*) ;; *) want="$want:latest" ;; esac
    if ! ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$want"; then
      echo "==> Pulling $model (this can take a while the first time)..."
      ollama pull "$model"
    fi
  done
}

# ─── Redpanda (Kafka-compatible) ─────────────────────────────────────────────
#
# Redpanda's broker binary is Linux-only; on macOS the recommended approach is
# Docker.  We try Docker first, then fall back to native rpk (works if you're
# on Linux or have a Redpanda build for your platform).

ensure_rpk_cli() {
  # rpk CLI (cross-platform, used only for topic management — NOT the broker)
  if ! command -v rpk >/dev/null 2>&1; then
    require_brew
    echo "==> Installing rpk CLI via Homebrew..."
    brew install redpanda-data/tap/redpanda || true   # non-fatal; Docker path doesn't need it
  fi
}

kafka_create_topics() {
  echo "==> Creating Kafka topics..."
  for topic in "events.raw" "events.masked" "session.analyze-requested"; do
    if command -v rpk >/dev/null 2>&1; then
      rpk topic create "$topic" --brokers "$KAFKA_BROKERS" --partitions 12 >/dev/null 2>&1 || true
    else
      # rpk not available; topics will be auto-created by the producer on first write
      echo "    (rpk not installed — topics will be auto-created on first event)"
      break
    fi
  done
}

start_kafka() {
  if is_up kafka; then
    echo "Redpanda already running (pid $(cat "$RUN_DIR/kafka.pid"))."
    return
  fi
  # Already running outside this script?
  if rpk cluster info --brokers "$KAFKA_BROKERS" >/dev/null 2>&1; then
    echo "Redpanda already reachable on $KAFKA_BROKERS (not started by this script)."
    kafka_create_topics
    return
  fi

  mkdir -p "$RUN_DIR/redpanda-data"

  # ── Docker path (recommended on macOS) ──────────────────────────────────────
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "==> Starting Redpanda via Docker on :9092..."
    # Remove any stale container from a previous run
    docker rm -f replayiq-redpanda >/dev/null 2>&1 || true
    nohup docker run --rm \
      --name replayiq-redpanda \
      -p 9092:9092 \
      -p 9644:9644 \
      -v "$RUN_DIR/redpanda-data:/var/lib/redpanda/data" \
      docker.redpanda.com/redpandadata/redpanda:latest \
      redpanda start \
      --overprovisioned \
      --smp 1 \
      --memory 512M \
      --reserve-memory 0M \
      --node-id 0 \
      --kafka-addr 0.0.0.0:9092 \
      --advertise-kafka-addr localhost:9092 \
      > "$RUN_DIR/kafka.log" 2>&1 &
    echo $! > "$RUN_DIR/kafka.pid"

    echo "    Waiting for Redpanda (Docker) to be ready..."
    for i in $(seq 1 45); do
      if rpk cluster info --brokers "$KAFKA_BROKERS" >/dev/null 2>&1 2>/dev/null || \
         docker exec replayiq-redpanda rpk cluster info >/dev/null 2>&1; then
        echo "    Redpanda ready."
        break
      fi
      sleep 2
    done

    kafka_create_topics
    return
  fi

  # ── Native rpk path (Linux, or macOS if broker binary is available) ─────────
  if ! command -v rpk >/dev/null 2>&1; then
    require_brew
    echo "==> Installing Redpanda (rpk) via Homebrew..."
    if ! brew install redpanda-data/tap/redpanda; then
      echo "ERROR: Could not install Redpanda. Install Docker Desktop for the easiest setup:" >&2
      echo "  https://www.docker.com/products/docker-desktop/" >&2
      exit 1
    fi
  fi

  echo "==> Starting Redpanda natively on :9092..."
  nohup rpk redpanda start \
    --overprovisioned \
    --smp 1 \
    --memory 512M \
    --reserve-memory 0M \
    --node-id 0 \
    --kafka-addr 0.0.0.0:9092 \
    --advertise-kafka-addr localhost:9092 \
    > "$RUN_DIR/kafka.log" 2>&1 &
  echo $! > "$RUN_DIR/kafka.pid"

  echo "    Waiting for Redpanda to be ready..."
  for i in $(seq 1 30); do
    rpk cluster info --brokers "$KAFKA_BROKERS" >/dev/null 2>&1 && echo "    Redpanda ready." && break
    sleep 2
  done

  kafka_create_topics
}

# ─── Build Go binaries ───────────────────────────────────────────────────────
cmd_build() {
  echo "==> Building Go services..."
  for svc in ingest processor query gateway; do
    echo "    building $svc..."
    go -C backend build -o "$RUN_DIR/replayiq-${svc}" "./cmd/${svc}"
  done
  echo "    done."
}

# ─── Start a single service ──────────────────────────────────────────────────
start_service() {
  local name="$1"; shift
  local bin="$1"; shift

  if is_up "$name"; then
    echo "$name already running (pid $(cat "$RUN_DIR/$name.pid"))."
    return
  fi

  echo "==> Starting $name..."
  nohup "$RUN_DIR/$bin" "$@" > "$RUN_DIR/$name.log" 2>&1 &
  echo $! > "$RUN_DIR/$name.pid"
}

# ─── Main up command ─────────────────────────────────────────────────────────
cmd_up() {
  ensure_postgres
  ensure_minio_installed
  start_minio
  ensure_ollama
  start_kafka
  cmd_build

  # Shared env values used by multiple services
  local DB_URL="$DATABASE_URL"
  local MINIO_EP="localhost:9000"
  local SDK="$(pwd)/sdk"

  # Ingest API (:8081)
  if is_up ingest; then
    echo "ingest already running (pid $(cat "$RUN_DIR/ingest.pid"))."
  else
    echo "==> Starting ingest service on :8081..."
    env DATABASE_URL="$DB_URL" \
        INGEST_PORT=8081 \
        SDK_PATH="$SDK" \
        KAFKA_BROKERS="$KAFKA_BROKERS" \
        nohup "$RUN_DIR/replayiq-ingest" > "$RUN_DIR/ingest.log" 2>&1 &
    echo $! > "$RUN_DIR/ingest.pid"
  fi

  # Processor (no HTTP port — Kafka consumer only)
  if is_up processor; then
    echo "processor already running (pid $(cat "$RUN_DIR/processor.pid"))."
  else
    echo "==> Starting processor service (Kafka consumer)..."
    env DATABASE_URL="$DB_URL" \
        MINIO_ENDPOINT="$MINIO_EP" \
        MINIO_ACCESS_KEY="$MINIO_ACCESS_KEY" \
        MINIO_SECRET_KEY="$MINIO_SECRET_KEY" \
        MINIO_BUCKET="sessions" \
        OLLAMA_ENDPOINT="http://localhost:11434" \
        OLLAMA_MODEL="$OLLAMA_MODEL" \
        EMBEDDING_MODEL="$EMBEDDING_MODEL" \
        KAFKA_BROKERS="$KAFKA_BROKERS" \
        nohup "$RUN_DIR/replayiq-processor" > "$RUN_DIR/processor.log" 2>&1 &
    echo $! > "$RUN_DIR/processor.pid"
  fi

  # Query API (:8082)
  if is_up query; then
    echo "query already running (pid $(cat "$RUN_DIR/query.pid"))."
  else
    echo "==> Starting query service on :8082..."
    env DATABASE_URL="$DB_URL" \
        QUERY_PORT=8082 \
        SDK_PATH="$SDK" \
        MINIO_ENDPOINT="$MINIO_EP" \
        MINIO_ACCESS_KEY="$MINIO_ACCESS_KEY" \
        MINIO_SECRET_KEY="$MINIO_SECRET_KEY" \
        MINIO_BUCKET="sessions" \
        OLLAMA_ENDPOINT="http://localhost:11434" \
        OLLAMA_MODEL="$OLLAMA_MODEL" \
        EMBEDDING_MODEL="$EMBEDDING_MODEL" \
        JIRA_BASE_URL="${JIRA_BASE_URL:-}" \
        JIRA_EMAIL="${JIRA_EMAIL:-}" \
        JIRA_API_TOKEN="${JIRA_API_TOKEN:-}" \
        JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-ENG}" \
        nohup "$RUN_DIR/replayiq-query" > "$RUN_DIR/query.log" 2>&1 &
    echo $! > "$RUN_DIR/query.pid"
  fi

  # Gateway (:8080 — public-facing, same port as the old monolith)
  if is_up gateway; then
    echo "gateway already running (pid $(cat "$RUN_DIR/gateway.pid"))."
  else
    echo "==> Starting gateway on :8080 → ingest:8081 / query:8082..."
    env GATEWAY_PORT=8080 \
        INGEST_URL="http://localhost:8081" \
        QUERY_URL="http://localhost:8082" \
        nohup "$RUN_DIR/replayiq-gateway" > "$RUN_DIR/gateway.log" 2>&1 &
    echo $! > "$RUN_DIR/gateway.pid"
  fi

  # Dashboard
  if is_up dashboard; then
    echo "Dashboard already running (pid $(cat "$RUN_DIR/dashboard.pid"))."
  else
    echo "==> Starting dashboard on :3000..."
    if [ ! -d dashboard/node_modules ]; then
      echo "    (installing dashboard deps first...)"
      npm --prefix dashboard install
    fi
    nohup npm --prefix dashboard run dev > "$RUN_DIR/dashboard.log" 2>&1 &
    echo $! > "$RUN_DIR/dashboard.pid"
  fi

  sleep 1
  echo
  echo "┌──────────────────────────────────────────────────────────────┐"
  echo "│  Gateway (public):  http://localhost:8080                    │"
  echo "│  Ingest API:        http://localhost:8081  (.dev/ingest.log) │"
  echo "│  Query API:         http://localhost:8082  (.dev/query.log)  │"
  echo "│  Processor:                                (.dev/processor.log)│"
  echo "│  Dashboard:         http://localhost:3000                    │"
  echo "│  MinIO console:     http://localhost:9001                    │"
  echo "│  Kafka:             localhost:9092         (.dev/kafka.log)  │"
  echo "└──────────────────────────────────────────────────────────────┘"
  echo
  echo "Run './dev.sh down' to stop everything."
  echo "Run './dev.sh logs [service]' to tail logs."
}

cmd_down() {
  for name in gateway ingest processor query dashboard minio ollama kafka; do
    if is_up "$name"; then
      echo "==> Stopping $name (pid $(cat "$RUN_DIR/$name.pid"))..."
      kill "$(cat "$RUN_DIR/$name.pid")" 2>/dev/null || true
    fi
    rm -f "$RUN_DIR/$name.pid"
    # Also stop Docker-managed Redpanda if it's still running
    if [ "$name" = "kafka" ] && command -v docker >/dev/null 2>&1; then
      docker rm -f replayiq-redpanda >/dev/null 2>&1 || true
    fi
  done
  echo "Native Postgres is left running (it's your system's, not this project's)."
}

reachable() { curl -sf "$1" >/dev/null 2>&1; }

cmd_status() {
  for name in gateway ingest processor query dashboard minio; do
    if is_up "$name"; then
      echo "$name: running (pid $(cat "$RUN_DIR/$name.pid"))"
    else
      echo "$name: stopped"
    fi
  done
  if is_up kafka; then
    echo "kafka/redpanda: running (pid $(cat "$RUN_DIR/kafka.pid"))"
  elif rpk cluster info --brokers "$KAFKA_BROKERS" >/dev/null 2>&1; then
    echo "kafka/redpanda: reachable (running outside this script)"
  else
    echo "kafka/redpanda: stopped"
  fi
  if is_up ollama; then
    echo "ollama: running (pid $(cat "$RUN_DIR/ollama.pid"))"
  elif reachable http://localhost:11434/api/tags; then
    echo "ollama: reachable (running outside this script)"
  else
    echo "ollama: stopped"
  fi
  pg_isready -q 2>/dev/null && echo "postgres: reachable (native, port 5432)" || echo "postgres: NOT reachable"
}

cmd_logs() {
  local svc="${1:-}"
  case "$svc" in
    ingest|processor|query|gateway|dashboard|minio|ollama|kafka)
      tail -f "$RUN_DIR/$svc.log" ;;
    *)
      tail -f "$RUN_DIR"/*.log ;;
  esac
}

case "${1:-up}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  build)  cmd_build ;;
  logs)   shift; cmd_logs "${1:-}" ;;
  *)      echo "Usage: $0 [up|down|status|build|logs [ingest|processor|query|gateway|dashboard|minio|ollama|kafka]]"; exit 1 ;;
esac
