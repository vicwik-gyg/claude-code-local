#!/usr/bin/env bash
# Comprehensive health check for claude-code-local
set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
RESET='\033[0m'

# ── Counters ─────────────────────────────────────────────────────────
PASS=0
WARN=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────────
section() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $1"; PASS=$((PASS + 1)); }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $1"; WARN=$((WARN + 1)); }
fail()    { echo -e "  ${RED}✗${RESET} $1"; FAIL=$((FAIL + 1)); }
info()    { echo -e "  ${DIM}$1${RESET}"; }
kv()      { printf "  %-24s %s\n" "$1" "$2"; }

# ── Globals ──────────────────────────────────────────────────────────
OS_NAME=$(uname -s)

# ── 1. Project files ────────────────────────────────────────────────
section "Project"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

kv "Location:" "$PROJECT_DIR"

EXPECTED_FILES=(
    "docker-compose.yml"
    "docker-compose.gpu.yml"
    "Makefile"
    "proxy/proxy.py"
    "proxy/Dockerfile"
    "proxy/requirements.txt"
    ".env.example"
)
MISSING=()
for f in "${EXPECTED_FILES[@]}"; do
    if [[ ! -f "$PROJECT_DIR/$f" ]]; then
        MISSING+=("$f")
    fi
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
    ok "All project files present (${#EXPECTED_FILES[@]}/${#EXPECTED_FILES[@]})"
else
    fail "Missing files: ${MISSING[*]}"
fi

if [[ -f "$PROJECT_DIR/.env" ]]; then
    ok ".env file exists"
else
    warn ".env file missing (copy from .env.example)"
fi

if command -v git &>/dev/null && git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
    BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "detached")
    DIRTY=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    COMMITS=$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo "0")
    kv "Git branch:" "$BRANCH"
    kv "Commits:" "$COMMITS"
    if [[ "$DIRTY" -gt 0 ]]; then
        warn "$DIRTY uncommitted change(s)"
    else
        ok "Working tree clean"
    fi
else
    info "Not a git repository"
fi

# ── 2. Dependencies ──────────────────────────────────────────────────
section "Dependencies"

REQUIRED_CMDS=("docker" "make" "curl" "python3")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd: $(command -v "$cmd")"
    else
        fail "$cmd: not found (see README.md for install instructions)"
    fi
done

if command -v node &>/dev/null; then
    ok "node: $(node --version 2>/dev/null) ($(command -v node))"
else
    warn "node: not found (needed to install Claude Code)"
fi

# ── 3. Docker ────────────────────────────────────────────────────────
section "Docker"

if ! command -v docker &>/dev/null; then
    fail "Docker not installed"
    kv "Install:" "https://docs.docker.com/get-docker/"
    echo ""
    echo -e "${RED}Cannot continue without Docker.${RESET}"
    exit 1
fi

kv "Docker CLI:" "$(docker --version 2>/dev/null | head -1)"

if docker info &>/dev/null; then
    ok "Docker daemon is running"
else
    fail "Docker daemon is not running"
    kv "Fix:" "Start Docker Desktop or run: sudo systemctl start docker"
    # Continue — remaining checks will report individual failures
fi

if docker compose version &>/dev/null; then
    kv "Compose:" "$(docker compose version --short 2>/dev/null)"
    ok "Docker Compose available"
else
    fail "Docker Compose not available"
fi

# Docker memory allocation
DOCKER_MEM_BYTES=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo "0")
if [[ "$DOCKER_MEM_BYTES" -gt 0 ]]; then
    DOCKER_MEM_GB=$(echo "$DOCKER_MEM_BYTES" | awk '{printf "%.1f", $1/1024/1024/1024}')
    DOCKER_MEM_GB_INT=$(echo "$DOCKER_MEM_GB" | awk '{printf "%.0f", $1}')
    kv "Memory allocated:" "${DOCKER_MEM_GB} GB"

    if [[ "$OS_NAME" == "Darwin" ]]; then
        info "Docker on macOS runs in a VM — models must fit in this allocation"
        info "Adjust in: Docker Desktop → Settings → Resources → Memory"
    fi
else
    DOCKER_MEM_GB="0"
    DOCKER_MEM_GB_INT="0"
    warn "Could not detect Docker memory allocation"
fi

# GPU runtime
if docker info 2>/dev/null | grep -qi nvidia; then
    ok "NVIDIA container runtime detected"
else
    info "No NVIDIA runtime (GPU support unavailable — that's fine for CPU)"
fi

# ── 3. Containers ────────────────────────────────────────────────────
section "Containers"

container_status() {
    local name=$1
    local state
    state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null | tr -d '\n' || echo "not found")
    if [[ -z "$state" ]]; then state="not found"; fi
    echo "$state"
}

OLLAMA_STATE=$(container_status "ollama")
PROXY_STATE=$(container_status "ollama-proxy")

if [[ "$OLLAMA_STATE" == "running" ]]; then
    ok "ollama: running"
    UPTIME=$(docker inspect --format '{{.State.StartedAt}}' ollama 2>/dev/null || echo "?")
    kv "  Started:" "$UPTIME"
    IMAGE=$(docker inspect --format '{{.Config.Image}}' ollama 2>/dev/null || echo "?")
    kv "  Image:" "$IMAGE"
elif [[ "$OLLAMA_STATE" == "not found" ]]; then
    fail "ollama: not created (run: make start)"
else
    fail "ollama: $OLLAMA_STATE (run: make start)"
fi

if [[ "$PROXY_STATE" == "running" ]]; then
    ok "ollama-proxy: running"
elif [[ "$PROXY_STATE" == "not found" || "$PROXY_STATE" == "exited" ]]; then
    info "ollama-proxy: not running (optional — start with: make start-proxy)"
else
    warn "ollama-proxy: $PROXY_STATE (unexpected state)"
fi

# ── 4. Network / Ports ──────────────────────────────────────────────
section "Network"

check_port() {
    local port=$1 label=$2
    if curl -sf --max-time 2 "http://localhost:$port/" &>/dev/null; then
        ok "$label (localhost:$port) — reachable"
        return 0
    else
        fail "$label (localhost:$port) — not reachable"
        return 1
    fi
}

OLLAMA_REACHABLE=false
if check_port 11434 "Ollama API"; then
    OLLAMA_REACHABLE=true
    # Get Ollama server version
    OLLAMA_VERSION=$(curl -sf --max-time 2 http://localhost:11434/api/version 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null \
        || echo "unknown")
    kv "  Ollama version:" "$OLLAMA_VERSION"
fi

PROXY_REACHABLE=false
if [[ "$PROXY_STATE" == "running" ]]; then
    if check_port 4000 "Logging proxy"; then
        PROXY_REACHABLE=true
    fi
else
    info "Proxy port 4000: skipped (proxy not running)"
fi

# ── 5. Models ────────────────────────────────────────────────────────
section "Models"

if [[ "$OLLAMA_STATE" == "running" ]]; then
    MODEL_OUTPUT=$(docker exec ollama ollama list 2>/dev/null || echo "")
    if [[ -n "$MODEL_OUTPUT" ]]; then
        MODEL_COUNT=$(echo "$MODEL_OUTPUT" | tail -n +2 | wc -l | tr -d ' ')
        if [[ "$MODEL_COUNT" -gt 0 ]]; then
            ok "$MODEL_COUNT model(s) downloaded:"
            echo ""
            # Print header + rows with formatting
            echo "$MODEL_OUTPUT" | head -1 | sed 's/^/    /'
            echo "$MODEL_OUTPUT" | tail -n +2 | sed 's/^/    /'
            echo ""
        else
            fail "No models downloaded"
            kv "Fix:" "make pull MODEL=qwen3-coder"
        fi
    else
        fail "Could not list models"
    fi

    # Check model sizes against Docker memory
    if [[ "$DOCKER_MEM_GB" != "0" ]]; then
        echo -e "  ${BOLD}Docker memory check:${RESET}"
        LARGEST_MODEL_GB=0
        LARGEST_MODEL_NAME=""
        docker exec ollama ollama list 2>/dev/null | tail -n +2 | while IFS= read -r line; do
            M_NAME=$(echo "$line" | awk '{print $1}')
            M_SIZE=$(echo "$line" | awk '{print $3}')
            M_UNIT=$(echo "$line" | awk '{print $4}')

            # Convert to GB
            M_GB=0
            if [[ "$M_UNIT" == "GB" ]]; then
                M_GB="$M_SIZE"
            elif [[ "$M_UNIT" == "MB" ]]; then
                M_GB=$(echo "$M_SIZE" | awk '{printf "%.1f", $1/1024}')
            fi

            # Model needs ~1.3x its size for runtime overhead
            NEEDED=$(echo "$M_GB" | awk '{printf "%.0f", $1 * 1.3 + 2}')

            if (( $(echo "$NEEDED <= $DOCKER_MEM_GB_INT" | bc -l 2>/dev/null || echo 0) )); then
                ok "$M_NAME (${M_SIZE} ${M_UNIT}) — fits in Docker memory (~${NEEDED} GB needed)"
            else
                fail "$M_NAME (${M_SIZE} ${M_UNIT}) — does NOT fit in Docker memory (~${NEEDED} GB needed, ${DOCKER_MEM_GB} GB allocated)"
                kv "    Fix:" "Increase Docker memory to ${NEEDED}+ GB"
                if [[ "$OS_NAME" == "Darwin" ]]; then
                    kv "    How:" "Docker Desktop → Settings → Resources → Memory"
                fi
            fi
        done
    fi

    # Check for Claude Code aliases
    echo ""
    echo -e "  ${BOLD}Claude Code aliases:${RESET}"
    info "Claude Code requires Anthropic model names. Create aliases with: make alias FROM=<model> TO=<name>"
    HAS_SONNET=$(docker exec ollama ollama list 2>/dev/null | grep -c "^claude-sonnet" | tr -d '[:space:]' || echo "0")
    HAS_HAIKU=$(docker exec ollama ollama list 2>/dev/null | grep -c "^claude-haiku" | tr -d '[:space:]' || echo "0")
    HAS_OPUS=$(docker exec ollama ollama list 2>/dev/null | grep -c "^claude-opus" | tr -d '[:space:]' || echo "0")

    if [[ "$HAS_SONNET" -gt 0 ]]; then
        SONNET_NAME=$(docker exec ollama ollama list 2>/dev/null | grep "^claude-sonnet" | head -1 | awk '{print $1}')
        ok "sonnet → $SONNET_NAME"
    else
        warn "No 'sonnet' alias (run: make alias FROM=<your-model> TO=claude-sonnet-4-6)"
    fi
    if [[ "$HAS_HAIKU" -gt 0 ]]; then
        HAIKU_NAME=$(docker exec ollama ollama list 2>/dev/null | grep "^claude-haiku" | head -1 | awk '{print $1}')
        ok "haiku → $HAIKU_NAME"
    else
        info "No 'haiku' alias (optional: make alias FROM=<small-model> TO=claude-haiku-3-5-20241022)"
    fi
    if [[ "$HAS_OPUS" -gt 0 ]]; then
        OPUS_NAME=$(docker exec ollama ollama list 2>/dev/null | grep "^claude-opus" | head -1 | awk '{print $1}')
        ok "opus → $OPUS_NAME"
    else
        info "No 'opus' alias (optional: make alias FROM=<large-model> TO=claude-opus-4-6)"
    fi

    # Disk usage for model storage
    VOLUME_SIZE=$(docker exec ollama du -sh /root/.ollama/models 2>/dev/null | awk '{print $1}' || echo "unknown")
    kv "Model storage:" "$VOLUME_SIZE"
else
    fail "Cannot check models — ollama container not running"
fi

# ── 6. Configuration ────────────────────────────────────────────────
section "Configuration"

echo -e "  ${BOLD}Shell environment:${RESET}"
if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    kv "  ANTHROPIC_BASE_URL:" "$ANTHROPIC_BASE_URL"
    if [[ "$ANTHROPIC_BASE_URL" == *":4000"* ]]; then
        info "  → Routing through proxy"
    elif [[ "$ANTHROPIC_BASE_URL" == *":11434/v1"* ]]; then
        ok "  → Direct to Ollama (correct /v1 path)"
    elif [[ "$ANTHROPIC_BASE_URL" == *":11434"* && "$ANTHROPIC_BASE_URL" != *"/v1"* ]]; then
        fail "  → Missing /v1 path suffix"
        kv "    Fix:" "export ANTHROPIC_BASE_URL=http://localhost:11434/v1"
    else
        warn "  → Unexpected URL (expected localhost:11434/v1 or localhost:4000/v1)"
    fi
else
    warn "ANTHROPIC_BASE_URL not set"
    kv "  Fix:" "export ANTHROPIC_BASE_URL=http://localhost:11434/v1"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    # Mask the key, show first 10 chars
    KEY_PREVIEW="${ANTHROPIC_API_KEY:0:10}..."
    kv "  ANTHROPIC_API_KEY:" "$KEY_PREVIEW"
    if [[ "${ANTHROPIC_API_KEY}" != sk-ant-api03-* ]]; then
        warn "  API key format may be invalid (should start with sk-ant-api03-)"
    fi
else
    warn "ANTHROPIC_API_KEY not set"
    kv "  Fix:" "export ANTHROPIC_API_KEY=sk-ant-api03-local-dummy-key-for-ollama-000000000000000000000000000000000000"
fi

if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    warn "ANTHROPIC_AUTH_TOKEN is set — this can conflict with ANTHROPIC_API_KEY"
    kv "    Fix:" "unset ANTHROPIC_AUTH_TOKEN"
fi

if [[ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ]]; then
    kv "  CLAUDE_CODE_USE_BEDROCK:" "$CLAUDE_CODE_USE_BEDROCK"
    if [[ "$CLAUDE_CODE_USE_BEDROCK" == "1" ]]; then
        fail "  Bedrock is enabled — Claude Code will not use ANTHROPIC_BASE_URL"
        kv "    Fix:" "export CLAUDE_CODE_USE_BEDROCK=0"
    fi
else
    info "  CLAUDE_CODE_USE_BEDROCK: not set (ok)"
fi

if [[ -n "${ANTHROPIC_MODEL:-}" ]]; then
    kv "  ANTHROPIC_MODEL:" "$ANTHROPIC_MODEL"
fi

echo ""
echo -e "  ${BOLD}.env file:${RESET}"
if [[ -f "$PROJECT_DIR/.env" ]]; then
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue
        KEY=$(echo "$line" | cut -d= -f1)
        VAL=$(echo "$line" | cut -d= -f2-)
        kv "  $KEY:" "$VAL"
    done < "$PROJECT_DIR/.env"
else
    info "  No .env file"
fi

# ── 7. Claude Code ──────────────────────────────────────────────────
section "Claude Code"

if command -v claude &>/dev/null; then
    ok "Claude Code installed"
    CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
    kv "Version:" "$CLAUDE_VERSION"
    CLAUDE_PATH=$(command -v claude)
    kv "Path:" "$CLAUDE_PATH"
else
    fail "Claude Code not installed"
    kv "Install:" "npm install -g @anthropic-ai/claude-code"
fi

# ── 8. API smoke test ───────────────────────────────────────────────
section "API Smoke Test"

DEFAULT_MODEL="${OLLAMA_DEFAULT_MODEL:-qwen3-coder}"

# Determine which endpoint to test
if [[ "$OLLAMA_REACHABLE" == "true" ]]; then
    TEST_URL="http://localhost:11434"

    # Select test model: MODEL env var > currently loaded model > smallest available
    RUNNING_MODEL=$(curl -sf --max-time 5 "$TEST_URL/api/ps" 2>/dev/null \
        | python3 -c "
import sys, json
models = json.load(sys.stdin).get('models', [])
if models:
    print(models[0].get('name', ''))
" 2>/dev/null || echo "")

    SMALLEST_MODEL=""
    if [[ "$OLLAMA_STATE" == "running" ]]; then
        SMALLEST_MODEL=$(docker exec ollama ollama list 2>/dev/null | tail -n +2 \
            | sort -k3 -n | head -1 | awk '{print $1}')
    fi

    if [[ -n "${MODEL:-}" ]]; then
        TEST_MODEL="$MODEL"
        info "Using model from MODEL=: $TEST_MODEL"
    elif [[ -n "$RUNNING_MODEL" ]]; then
        TEST_MODEL="$RUNNING_MODEL"
        info "Using currently loaded model: $TEST_MODEL"
    elif [[ -n "$SMALLEST_MODEL" ]]; then
        TEST_MODEL="$SMALLEST_MODEL"
        info "Using smallest available model: $TEST_MODEL"
    else
        fail "No models available for API test"
        kv "Fix:" "make pull MODEL=$DEFAULT_MODEL"
        TEST_MODEL=""
    fi

    if [[ -n "$TEST_MODEL" ]]; then
        # ── Test 1: Ollama native API ──
        echo ""
        echo -e "  ${BOLD}1. Ollama native API (/api/generate):${RESET}"
        NATIVE_RESPONSE=$(curl -sf --max-time 120 "$TEST_URL/api/generate" \
            -d "{\"model\":\"$TEST_MODEL\",\"prompt\":\"What is 2+2? Answer with just the number, no explanation. /no_think\",\"stream\":false}" \
            2>/dev/null || echo "FAILED")

        if [[ "$NATIVE_RESPONSE" == "FAILED" ]]; then
            fail "Ollama native API call failed"
        else
            NATIVE_TEXT=$(echo "$NATIVE_RESPONSE" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    if 'error' in r:
        print('ERROR:' + str(r['error']))
    else:
        text = r.get('response', '(empty)').strip()
        dur_ns = r.get('total_duration', 0)
        eval_count = r.get('eval_count', 0)
        eval_dur_ns = r.get('eval_duration', 1)
        tok_per_sec = eval_count / (eval_dur_ns / 1e9) if eval_dur_ns > 0 else 0
        total_sec = dur_ns / 1e9 if dur_ns > 0 else 0
        print(f'TEXT={text[:200]}')
        print(f'TOTAL_TIME={total_sec:.1f}')
        print(f'TOKENS={eval_count}')
        print(f'SPEED={tok_per_sec:.1f}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>/dev/null || echo "ERROR:could not parse response")

            if [[ "$NATIVE_TEXT" == ERROR:* ]]; then
                fail "Ollama API error: ${NATIVE_TEXT#ERROR:}"
            else
                ok "Ollama native API working"
                while IFS= read -r line; do
                    case "$line" in
                        TEXT=*)       kv "  Response:" "\"${line#TEXT=}\"" ;;
                        TOTAL_TIME=*) kv "  Total time:" "${line#TOTAL_TIME=}s" ;;
                        TOKENS=*)     kv "  Tokens generated:" "${line#TOKENS=}" ;;
                        SPEED=*)      kv "  Speed:" "${line#SPEED=} tokens/sec" ;;
                    esac
                done <<< "$NATIVE_TEXT"
            fi
        fi

        # ── Test 2: Anthropic Messages API ──
        echo ""
        echo -e "  ${BOLD}2. Anthropic Messages API (/v1/messages):${RESET}"
        info "This is the API that Claude Code uses."

        API_RESPONSE=$(curl -sf --max-time 120 "$TEST_URL/v1/messages" \
            -H "Content-Type: application/json" \
            -H "x-api-key: ollama" \
            -H "anthropic-version: 2023-06-01" \
            -d "{\"model\":\"$TEST_MODEL\",\"max_tokens\":512,\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2? Answer with just the number, no explanation. /no_think\"}]}" \
            2>/dev/null || echo "FAILED")

        if [[ "$API_RESPONSE" == "FAILED" ]]; then
            fail "Anthropic Messages API call failed"
            info "The model may not support the Anthropic API format."
            info "Ensure Ollama v0.14.0+ is installed."
        else
            RESPONSE_TEXT=$(echo "$API_RESPONSE" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    if 'error' in r:
        print('ERROR:' + str(r['error'].get('message', r['error'])))
    elif 'content' in r:
        # Find the text block (skip thinking blocks from Qwen3 etc.)
        text = ''
        thinking_text = ''
        for block in r['content']:
            if block.get('type') == 'text' and block.get('text', '').strip():
                text = block['text'].strip()
                break
            elif block.get('type') == 'thinking' and block.get('thinking', '').strip():
                thinking_text = block['thinking'].strip()
        # If no text block but thinking is present, show thinking snippet
        if not text and thinking_text:
            text = '(thinking only) ' + thinking_text[:100]
        elif not text:
            text = '(empty)'
        model = r.get('model', '?')
        usage = r.get('usage', {})
        input_tok = usage.get('input_tokens', '?')
        output_tok = usage.get('output_tokens', '?')
        stop = r.get('stop_reason', r.get('stop_sequence', '?'))
        has_thinking = any(b.get('type') == 'thinking' for b in r['content'])
        print(f'MODEL={model}')
        print(f'TEXT={text[:200]}')
        print(f'INPUT_TOKENS={input_tok}')
        print(f'OUTPUT_TOKENS={output_tok}')
        print(f'STOP_REASON={stop}')
        if has_thinking:
            print(f'THINKING=yes')
    else:
        print('ERROR:unexpected response format')
except Exception as e:
    print(f'ERROR:{e}')
" 2>/dev/null || echo "ERROR:could not parse response")

            if [[ "$RESPONSE_TEXT" == ERROR:* ]]; then
                fail "API returned error: ${RESPONSE_TEXT#ERROR:}"
            else
                ok "Anthropic Messages API working"
                while IFS= read -r line; do
                    case "$line" in
                        MODEL=*)    kv "  Model:" "${line#MODEL=}" ;;
                        TEXT=*)     kv "  Response:" "\"${line#TEXT=}\"" ;;
                        INPUT_TOKENS=*)  kv "  Input tokens:" "${line#INPUT_TOKENS=}" ;;
                        OUTPUT_TOKENS=*) kv "  Output tokens:" "${line#OUTPUT_TOKENS=}" ;;
                        STOP_REASON=*)   kv "  Stop reason:" "${line#STOP_REASON=}" ;;
                        THINKING=*)      info "  Model used thinking mode (thinking + text blocks)" ;;
                    esac
                done <<< "$RESPONSE_TEXT"
            fi
        fi

        # ── Test 3: Proxy passthrough ──
        if [[ "$PROXY_REACHABLE" == "true" ]]; then
            echo ""
            echo -e "  ${BOLD}3. Proxy passthrough (:4000 → :11434):${RESET}"
            PROXY_RESPONSE=$(curl -sf --max-time 120 "http://localhost:4000/v1/messages" \
                -H "Content-Type: application/json" \
                -H "x-api-key: ollama" \
                -H "anthropic-version: 2023-06-01" \
                -d "{\"model\":\"$TEST_MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}" \
                2>/dev/null || echo "FAILED")

            if [[ "$PROXY_RESPONSE" == "FAILED" ]]; then
                fail "Proxy passthrough failed"
            else
                ok "Proxy passthrough working"
            fi
        fi
    fi
else
    fail "Cannot run API test — Ollama not reachable"
    kv "Fix:" "make start"
fi

# ── 9. Host System ───────────────────────────────────────────────────
section "Host System"

kv "OS:" "$OS_NAME ($(uname -m))"

# Total RAM
get_total_ram_gb() {
    if [[ "$OS_NAME" == "Darwin" ]]; then
        sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}'
    else
        grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024/1024}'
    fi
}

get_available_ram_gb() {
    if [[ "$OS_NAME" == "Darwin" ]]; then
        # macOS: use vm_stat to estimate free + inactive pages
        local page_size
        page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
        vm_stat 2>/dev/null | awk -v ps="$page_size" '
            /Pages free/    { free = $NF+0 }
            /Pages inactive/{ inactive = $NF+0 }
            /Pages purgeable/{ purgeable = $NF+0 }
            END { printf "%.1f", (free + inactive + purgeable) * ps / 1024/1024/1024 }
        '
    else
        grep MemAvailable /proc/meminfo 2>/dev/null | awk '{printf "%.1f", $2/1024/1024}'
    fi
}

TOTAL_RAM=$(get_total_ram_gb)
AVAILABLE_RAM=$(get_available_ram_gb)

if [[ -n "$TOTAL_RAM" && "$TOTAL_RAM" != "0" ]]; then
    kv "Total RAM:" "${TOTAL_RAM} GB"
    kv "Available RAM:" "${AVAILABLE_RAM} GB (approx)"

    # Model sizing guidance
    echo ""
    echo -e "  ${BOLD}Model compatibility (based on ${TOTAL_RAM} GB total RAM):${RESET}"
    if [[ "$TOTAL_RAM" -ge 48 ]]; then
        ok "Can run 70B models (e.g. qwen3-coder:70b, llama3.1:70b)"
        ok "Can run 30B models (e.g. qwen3-coder:30b)"
        ok "Can run 14B models (e.g. qwen3-coder, deepseek-r1:14b)"
        ok "Can run 7-8B models (e.g. llama3.1:8b)"
    elif [[ "$TOTAL_RAM" -ge 24 ]]; then
        warn "70B models will not fit — need 48+ GB"
        ok "Can run 30B models (e.g. qwen3-coder:30b)"
        ok "Can run 14B models (e.g. qwen3-coder, deepseek-r1:14b)"
        ok "Can run 7-8B models (e.g. llama3.1:8b)"
    elif [[ "$TOTAL_RAM" -ge 12 ]]; then
        warn "70B models will not fit — need 48+ GB"
        warn "30B models will be tight — need 24+ GB"
        ok "Can run 14B models (e.g. qwen3-coder, deepseek-r1:14b)"
        ok "Can run 7-8B models (e.g. llama3.1:8b)"
    elif [[ "$TOTAL_RAM" -ge 6 ]]; then
        warn "70B/30B/14B models will not fit"
        ok "Can run 7-8B models (e.g. llama3.1:8b)"
        info "For Claude Code, 7B models will have limited tool use capability"
    else
        fail "Very low RAM (${TOTAL_RAM} GB) — may struggle with any model"
        kv "  Minimum:" "8 GB for smallest usable models"
    fi

    # Check currently downloaded models against RAM
    if [[ "$OLLAMA_STATE" == "running" ]]; then
        echo ""
        echo -e "  ${BOLD}Downloaded model analysis:${RESET}"
        docker exec ollama ollama list 2>/dev/null | tail -n +2 | while IFS= read -r line; do
            MODEL_NAME=$(echo "$line" | awk '{print $1}')
            MODEL_SIZE=$(echo "$line" | awk '{print $3, $4}')
            # Extract numeric size in GB
            SIZE_NUM=$(echo "$MODEL_SIZE" | grep -oE '[0-9.]+' | head -1)
            SIZE_UNIT=$(echo "$MODEL_SIZE" | grep -oE '[A-Z]+' | head -1)

            # Estimate RAM needed (model size × ~1.2 for overhead)
            RAM_NEEDED=""
            if [[ "$SIZE_UNIT" == "GB" ]]; then
                RAM_NEEDED=$(echo "$SIZE_NUM" | awk '{printf "%.0f", $1 * 1.2}')
            elif [[ "$SIZE_UNIT" == "MB" ]]; then
                RAM_NEEDED=$(echo "$SIZE_NUM" | awk '{printf "%.1f", $1 * 1.2 / 1024}')
            fi

            if [[ -n "$RAM_NEEDED" ]]; then
                FITS=$(echo "$RAM_NEEDED $AVAILABLE_RAM" | awk '{print ($1 <= $2) ? "yes" : "no"}')
                if [[ "$FITS" == "yes" ]]; then
                    ok "$MODEL_NAME (${MODEL_SIZE}) — fits in available RAM (~${RAM_NEEDED} GB needed)"
                else
                    warn "$MODEL_NAME (${MODEL_SIZE}) — may not fit (~${RAM_NEEDED} GB needed, ${AVAILABLE_RAM} GB available)"
                fi
            else
                info "$MODEL_NAME ($MODEL_SIZE)"
            fi
        done
    fi
else
    warn "Could not detect system RAM"
fi

# GPU detection
echo ""
echo -e "  ${BOLD}GPU:${RESET}"
if [[ "$OS_NAME" == "Darwin" ]]; then
    # macOS: check for Apple Silicon (unified memory = GPU memory)
    CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
    if [[ "$CHIP" == *"Apple"* ]]; then
        ok "Apple Silicon detected ($CHIP)"
        info "Unified memory — GPU uses same RAM as CPU"
        info "Ollama automatically uses Metal acceleration"
    else
        info "Intel Mac — CPU-only inference (no GPU acceleration)"
    fi
elif command -v nvidia-smi &>/dev/null; then
    NVIDIA_INFO=$(nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits 2>/dev/null || echo "")
    if [[ -n "$NVIDIA_INFO" ]]; then
        while IFS=',' read -r gpu_name gpu_mem_total gpu_mem_free; do
            gpu_name=$(echo "$gpu_name" | xargs)
            gpu_total_gb=$(echo "$gpu_mem_total" | awk '{printf "%.0f", $1/1024}')
            gpu_free_gb=$(echo "$gpu_mem_free" | awk '{printf "%.0f", $1/1024}')
            ok "$gpu_name (${gpu_total_gb} GB total, ${gpu_free_gb} GB free)"
        done <<< "$NVIDIA_INFO"
        info "Use 'make start-gpu' to enable GPU acceleration"
    fi
else
    info "No NVIDIA GPU detected — CPU inference only"
fi

# ── 10. Disk & Docker Resources ─────────────────────────────────────
section "Disk & Docker"

# Docker disk usage for this project
if docker info &>/dev/null; then
    VOLUME_INFO=$(docker volume inspect claude-code-local_ollama_data 2>/dev/null || echo "")
    if [[ -n "$VOLUME_INFO" ]]; then
        MOUNTPOINT=$(echo "$VOLUME_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)[0].get('Mountpoint','?'))" 2>/dev/null || echo "?")
        kv "Volume mountpoint:" "$MOUNTPOINT"
    else
        info "Volume not created yet (starts after first make start)"
    fi

    # Container resource usage
    if [[ "$OLLAMA_STATE" == "running" ]]; then
        STATS=$(docker stats ollama --no-stream --format "{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null || echo "")
        if [[ -n "$STATS" ]]; then
            CPU=$(echo "$STATS" | cut -f1)
            MEM=$(echo "$STATS" | cut -f2)
            MEM_PCT=$(echo "$STATS" | cut -f3)
            kv "Ollama CPU:" "$CPU"
            kv "Ollama memory:" "$MEM ($MEM_PCT)"
        fi
    fi
fi

# Host disk space
DISK_FREE=$(df -h "$PROJECT_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
kv "Host disk free:" "${DISK_FREE:-unknown}"

# Disk space guidance
if [[ -n "$DISK_FREE" ]]; then
    # Extract numeric value (handles both "131Gi" and "131G" formats)
    DISK_NUM=$(echo "$DISK_FREE" | grep -oE '[0-9.]+' | head -1)
    DISK_UNIT=$(echo "$DISK_FREE" | grep -oE '[A-Za-z]+' | head -1)
    if [[ "$DISK_UNIT" == *"G"* ]] && (( $(echo "$DISK_NUM < 20" | bc -l 2>/dev/null || echo 0) )); then
        warn "Low disk space — models need 2-40+ GB each"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────
section "Summary"

TOTAL=$((PASS + WARN + FAIL))
echo -e "  ${GREEN}$PASS passed${RESET}  ${YELLOW}$WARN warnings${RESET}  ${RED}$FAIL failed${RESET}  (${TOTAL} checks)"

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    echo ""
    echo -e "  ${GREEN}${BOLD}Everything looks good.${RESET}"
    echo -e "  Run: ${BOLD}claude --model sonnet${RESET}"
elif [[ $FAIL -eq 0 ]]; then
    echo ""
    echo -e "  ${YELLOW}${BOLD}Mostly healthy with minor issues.${RESET}"
else
    echo ""
    echo -e "  ${RED}${BOLD}Issues detected — see FAIL items above.${RESET}"
fi

echo ""
exit $FAIL
