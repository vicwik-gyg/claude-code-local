#!/usr/bin/env bash
# Comprehensive health check for claude-code-local
set -euo pipefail

# ── Colors & helpers ────────────────────────────────────────────────
BOLD='\033[1m' DIM='\033[2m' GREEN='\033[32m' YELLOW='\033[33m' RED='\033[31m' CYAN='\033[36m' RESET='\033[0m'
PASS=0 WARN=0 FAIL=0
FAILURES=()

section() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $1"; PASS=$((PASS + 1)); }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $1"; WARN=$((WARN + 1)); }
fail()    { echo -e "  ${RED}✗${RESET} $1"; FAIL=$((FAIL + 1)); FAILURES+=("$1"); }
info()    { echo -e "  ${DIM}$1${RESET}"; }
kv()      { printf "  %-24s %s\n" "$1" "$2"; }

OS_NAME=$(uname -s)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── 1. Project ─────────────────────────────────────────────────────
section "Project"
kv "Location:" "$PROJECT_DIR"

EXPECTED_FILES=("docker-compose.yml" "docker-compose.gpu.yml" "Makefile" "proxy/proxy.py" "proxy/Dockerfile" "proxy/requirements.txt" ".env.example")
MISSING=()
for f in "${EXPECTED_FILES[@]}"; do
    [[ ! -f "$PROJECT_DIR/$f" ]] && MISSING+=("$f")
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
    ok "All project files present (${#EXPECTED_FILES[@]}/${#EXPECTED_FILES[@]})"
else
    fail "Missing files: ${MISSING[*]}"
fi

if command -v git &>/dev/null && git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
    kv "Git:" "$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo detached)"
    DIRTY=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [[ "$DIRTY" -gt 0 ]] && warn "$DIRTY uncommitted change(s)" || ok "Working tree clean"
fi

# ── 2. Dependencies ────────────────────────────────────────────────
section "Dependencies"
for cmd in docker make curl python3; do
    command -v "$cmd" &>/dev/null && ok "$cmd: $(command -v "$cmd")" || fail "$cmd: not found"
done
command -v claude &>/dev/null && ok "claude: $(claude --version 2>/dev/null)" || fail "claude: not found (npm install -g @anthropic-ai/claude-code)"

# ── 3. Docker ──────────────────────────────────────────────────────
section "Docker"
if ! docker info &>/dev/null; then
    fail "Docker daemon not running"
else
    ok "Docker daemon running"
    kv "Compose:" "$(docker compose version --short 2>/dev/null || echo 'not found')"
fi

DOCKER_MEM_BYTES=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo "0")
DOCKER_MEM_GB="0"
if [[ "$DOCKER_MEM_BYTES" -gt 0 ]]; then
    DOCKER_MEM_GB=$(echo "$DOCKER_MEM_BYTES" | awk '{printf "%.1f", $1/1024/1024/1024}')
    kv "Memory:" "${DOCKER_MEM_GB} GB"
    [[ "$OS_NAME" == "Darwin" ]] && info "macOS Docker runs in a VM — models must fit in this allocation"
fi

# ── 4. Containers ──────────────────────────────────────────────────
section "Containers"
container_status() {
    docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null | tr -d '\n' || echo "not found"
}
OLLAMA_STATE=$(container_status "ollama")
PROXY_STATE=$(container_status "ollama-proxy")

if [[ "$OLLAMA_STATE" == "running" ]]; then
    ok "ollama: running ($(docker inspect --format '{{.Config.Image}}' ollama 2>/dev/null))"
else
    fail "ollama: $OLLAMA_STATE (run: make start)"
fi
[[ "$PROXY_STATE" == "running" ]] && ok "proxy: running" || info "proxy: not running (optional)"

# ── 5. Network ─────────────────────────────────────────────────────
section "Network"
OLLAMA_REACHABLE=false
if curl -sf --max-time 2 http://localhost:11434/ &>/dev/null; then
    OLLAMA_REACHABLE=true
    OLLAMA_VERSION=$(curl -sf --max-time 2 http://localhost:11434/api/version 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
    ok "Ollama API reachable (v${OLLAMA_VERSION})"
else
    fail "Ollama API not reachable (localhost:11434)"
fi
if [[ "$PROXY_STATE" == "running" ]]; then
    curl -sf --max-time 2 http://localhost:4000/ &>/dev/null && ok "Proxy reachable (localhost:4000)" || fail "Proxy not reachable"
fi

# ── 6. Models ──────────────────────────────────────────────────────
section "Models"
MODEL_LIST=""
if [[ "$OLLAMA_STATE" == "running" ]]; then
    MODEL_LIST=$(docker exec ollama ollama list 2>/dev/null || echo "")
fi

if [[ -n "$MODEL_LIST" ]]; then
    MODEL_COUNT=$(echo "$MODEL_LIST" | tail -n +2 | wc -l | tr -d ' ')
    if [[ "$MODEL_COUNT" -gt 0 ]]; then
        ok "$MODEL_COUNT model(s) downloaded:"
        echo ""
        echo "$MODEL_LIST" | sed 's/^/    /'
        echo ""

        # Check model sizes against Docker memory
        DOCKER_MEM_INT=$(echo "$DOCKER_MEM_GB" | awk '{printf "%.0f", $1}')
        if [[ "$DOCKER_MEM_INT" -gt 0 ]]; then
            echo "$MODEL_LIST" | tail -n +2 | while IFS= read -r line; do
                M_NAME=$(echo "$line" | awk '{print $1}')
                M_SIZE=$(echo "$line" | awk '{print $3}')
                M_UNIT=$(echo "$line" | awk '{print $4}')
                M_GB=0
                [[ "$M_UNIT" == "GB" ]] && M_GB="$M_SIZE"
                [[ "$M_UNIT" == "MB" ]] && M_GB=$(echo "$M_SIZE" | awk '{printf "%.1f", $1/1024}')
                NEEDED=$(echo "$M_GB" | awk '{printf "%.0f", $1 * 1.3 + 2}')
                if (( $(echo "$NEEDED <= $DOCKER_MEM_INT" | bc -l 2>/dev/null || echo 0) )); then
                    ok "$M_NAME — fits in Docker memory (~${NEEDED} GB needed)"
                else
                    fail "$M_NAME — needs ~${NEEDED} GB, Docker has ${DOCKER_MEM_GB} GB"
                fi
            done
        fi
    else
        fail "No models downloaded (run: make pull MODEL=qwen3:1.7b)"
    fi

    # Claude Code aliases
    echo ""
    echo -e "  ${BOLD}Claude Code aliases:${RESET}"
    for alias_pair in "sonnet:claude-sonnet" "haiku:claude-haiku" "opus:claude-opus"; do
        ALIAS="${alias_pair%%:*}"
        PATTERN="${alias_pair##*:}"
        MATCH=$(echo "$MODEL_LIST" | grep "^${PATTERN}" | head -1 | awk '{print $1}')
        if [[ -n "$MATCH" ]]; then
            ok "$ALIAS → $MATCH"
        else
            [[ "$ALIAS" == "sonnet" ]] && warn "No '$ALIAS' alias (run: make alias FROM=<model> TO=claude-sonnet-4-6)" \
                || info "No '$ALIAS' alias (optional)"
        fi
    done
else
    fail "Cannot list models — ollama not running"
fi

# ── 7. Configuration ──────────────────────────────────────────────
section "Configuration"

if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    kv "ANTHROPIC_BASE_URL:" "$ANTHROPIC_BASE_URL"
    if [[ "$ANTHROPIC_BASE_URL" == *":11434/v1"* ]]; then
        ok "URL has correct /v1 path"
    elif [[ "$ANTHROPIC_BASE_URL" == *":11434"* ]]; then
        fail "Missing /v1 suffix — export ANTHROPIC_BASE_URL=http://localhost:11434/v1"
    elif [[ "$ANTHROPIC_BASE_URL" == *":4000"* ]]; then
        info "Routing through proxy"
    fi
else
    warn "ANTHROPIC_BASE_URL not set"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    kv "ANTHROPIC_API_KEY:" "${ANTHROPIC_API_KEY:0:10}..."
    [[ "${ANTHROPIC_API_KEY}" != sk-ant-api03-* ]] && warn "Key format should start with sk-ant-api03-"
else
    warn "ANTHROPIC_API_KEY not set"
fi

[[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]] && warn "ANTHROPIC_AUTH_TOKEN set — conflicts with ANTHROPIC_API_KEY (unset it)"
[[ "${CLAUDE_CODE_USE_BEDROCK:-}" == "1" ]] && fail "CLAUDE_CODE_USE_BEDROCK=1 — will bypass ANTHROPIC_BASE_URL (set to 0)"

# ── 8. API Smoke Test ─────────────────────────────────────────────
section "API Smoke Test"

if [[ "$OLLAMA_REACHABLE" == "true" && -n "$MODEL_LIST" ]]; then
    TEST_URL="http://localhost:11434"

    # Select model: MODEL env > loaded model > smallest available
    TEST_MODEL="${MODEL:-}"
    if [[ -z "$TEST_MODEL" ]]; then
        TEST_MODEL=$(curl -sf --max-time 5 "$TEST_URL/api/ps" 2>/dev/null \
            | python3 -c "import sys,json; m=json.load(sys.stdin).get('models',[]); print(m[0]['name'] if m else '')" 2>/dev/null || echo "")
    fi
    if [[ -z "$TEST_MODEL" ]]; then
        TEST_MODEL=$(echo "$MODEL_LIST" | tail -n +2 | sort -k3 -n | head -1 | awk '{print $1}')
    fi
    info "Testing with: $TEST_MODEL"

    # Test 1: Ollama native API
    echo ""
    echo -e "  ${BOLD}1. Ollama native API:${RESET}"
    NATIVE=$(curl -sf --max-time 120 "$TEST_URL/api/generate" \
        -d "{\"model\":\"$TEST_MODEL\",\"prompt\":\"What is 2+2? Answer with just the number. /no_think\",\"stream\":false}" 2>/dev/null || echo "")
    if [[ -n "$NATIVE" ]]; then
        PARSED=$(echo "$NATIVE" | python3 -c "
import sys,json
r=json.load(sys.stdin)
if 'error' in r: print('ERROR:'+str(r['error']))
else:
    t=r.get('response','?').strip()[:100]
    s=r.get('eval_count',0)/(r.get('eval_duration',1)/1e9) if r.get('eval_duration',0)>0 else 0
    print(f'OK|{t}|{s:.1f} tok/s')
" 2>/dev/null || echo "ERROR:parse failed")
        if [[ "$PARSED" == ERROR:* ]]; then fail "${PARSED#ERROR:}"
        else
            IFS='|' read -r _ text speed <<< "$PARSED"
            ok "Working — \"$text\" ($speed)"
        fi
    else fail "No response"; fi

    # Test 2: Anthropic Messages API
    echo ""
    echo -e "  ${BOLD}2. Anthropic Messages API (/v1/messages):${RESET}"
    API=$(curl -sf --max-time 120 "$TEST_URL/v1/messages" \
        -H "Content-Type: application/json" -H "x-api-key: test" -H "anthropic-version: 2023-06-01" \
        -d "{\"model\":\"$TEST_MODEL\",\"max_tokens\":512,\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2? Answer with just the number. /no_think\"}]}" 2>/dev/null || echo "")
    if [[ -n "$API" ]]; then
        PARSED=$(echo "$API" | python3 -c "
import sys,json
r=json.load(sys.stdin)
if 'error' in r: print('ERROR:'+str(r['error'].get('message',r['error'])))
elif 'content' in r:
    text=next((b['text'].strip() for b in r['content'] if b.get('type')=='text' and b.get('text','').strip()),'')
    if not text:
        text='(thinking only) '+next((b['thinking'][:80] for b in r['content'] if b.get('type')=='thinking'),'?')
    has_think='yes' if any(b.get('type')=='thinking' for b in r['content']) else 'no'
    print(f'OK|{text[:100]}|{r.get(\"model\",\"?\")}|thinking={has_think}')
else: print('ERROR:unexpected format')
" 2>/dev/null || echo "ERROR:parse failed")
        if [[ "$PARSED" == ERROR:* ]]; then fail "${PARSED#ERROR:}"
        else
            IFS='|' read -r _ text model extra <<< "$PARSED"
            ok "Working — \"$text\" (model=$model, $extra)"
        fi
    else fail "No response (ensure Ollama v0.14.0+)"; fi

    # Test 3: Proxy passthrough
    if [[ "$PROXY_STATE" == "running" ]]; then
        echo ""
        echo -e "  ${BOLD}3. Proxy passthrough:${RESET}"
        PROXY_OK=$(curl -sf --max-time 30 "http://localhost:4000/v1/messages" \
            -H "Content-Type: application/json" -H "x-api-key: test" -H "anthropic-version: 2023-06-01" \
            -d "{\"model\":\"$TEST_MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}" 2>/dev/null && echo "yes" || echo "no")
        [[ "$PROXY_OK" == "yes" ]] && ok "Proxy passthrough working" || fail "Proxy passthrough failed"
    fi
else
    fail "Cannot run API test — Ollama not reachable or no models"
fi

# ── 9. Host System ────────────────────────────────────────────────
section "Host System"
kv "OS:" "$OS_NAME ($(uname -m))"

if [[ "$OS_NAME" == "Darwin" ]]; then
    TOTAL_RAM=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')
    CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
    [[ "$CHIP" == *"Apple"* ]] && ok "$CHIP (unified memory, Metal acceleration)" || info "Intel Mac — CPU only"
else
    TOTAL_RAM=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024/1024}' || echo "0")
    command -v nvidia-smi &>/dev/null && ok "NVIDIA GPU detected" || info "No NVIDIA GPU — CPU only"
fi
[[ "${TOTAL_RAM:-0}" -gt 0 ]] && kv "Total RAM:" "${TOTAL_RAM} GB"

# Disk
DISK_FREE=$(df -h "$PROJECT_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
kv "Disk free:" "${DISK_FREE:-unknown}"

if [[ "$OLLAMA_STATE" == "running" ]]; then
    STATS=$(docker stats ollama --no-stream --format "CPU={{.CPUPerc}} MEM={{.MemUsage}}" 2>/dev/null || echo "")
    [[ -n "$STATS" ]] && kv "Ollama resources:" "$STATS"
fi

# ── Summary ───────────────────────────────────────────────────────
section "Summary"
TOTAL=$((PASS + WARN + FAIL))
echo -e "  ${GREEN}$PASS passed${RESET}  ${YELLOW}$WARN warnings${RESET}  ${RED}$FAIL failed${RESET}  (${TOTAL} checks)"
if [[ $FAIL -eq 0 ]]; then
    echo -e "\n  ${GREEN}${BOLD}Ready.${RESET} Run: ${BOLD}claude-local --model sonnet${RESET}"
else
    echo -e "\n  ${RED}${BOLD}Failed checks:${RESET}"
    for msg in "${FAILURES[@]}"; do
        echo -e "    ${RED}✗${RESET} $msg"
    done
fi
echo ""
exit $FAIL
