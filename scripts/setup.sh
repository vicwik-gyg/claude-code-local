#!/usr/bin/env bash
# One-command setup for claude-code-local
set -euo pipefail

# ── Colors & helpers ────────────────────────────────────────────────
BOLD='\033[1m' DIM='\033[2m' GREEN='\033[32m' YELLOW='\033[33m' RED='\033[31m' CYAN='\033[36m' RESET='\033[0m'

section() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $1"; }
skip()    { echo -e "  ${DIM}⊘ $1 (already done)${RESET}"; }
info()    { echo -e "  ${DIM}$1${RESET}"; }
die()     { echo -e "\n  ${RED}✗ $1${RESET}\n"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

MODEL="${MODEL:-qwen3-coder}"
ALIAS_NAME="claude-sonnet-4-6"
DUMMY_KEY="sk-ant-api03-local-dummy-key-for-ollama-000000000000000000000000000000000000"

echo -e "\n${BOLD}claude-code-local setup${RESET}"
echo -e "${DIM}Model: ${MODEL} → ${ALIAS_NAME}${RESET}"

# ── 1. Prerequisites ───────────────────────────────────────────────
section "Prerequisites"
for cmd in docker make curl; do
    command -v "$cmd" &>/dev/null && ok "$cmd: $(command -v "$cmd")" || die "$cmd is required but not found. Install it first."
done
docker compose version &>/dev/null && ok "docker compose: $(docker compose version --short 2>/dev/null)" || die "docker compose v2 is required but not found."
command -v claude &>/dev/null && ok "claude: $(claude --version 2>/dev/null)" || info "claude not found — install later with: npm install -g @anthropic-ai/claude-code"

# ── 2. Start Ollama ────────────────────────────────────────────────
section "Start Ollama"
OLLAMA_STATE=$(docker inspect --format '{{.State.Status}}' ollama 2>/dev/null || echo "not found")
if [[ "$OLLAMA_STATE" == "running" ]]; then
    skip "Ollama container running"
else
    info "Starting Ollama container..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d
    ok "Ollama container started"
fi

# ── 3. Wait for API ────────────────────────────────────────────────
section "Wait for API"
MAX_ATTEMPTS=30
ATTEMPT=0
while ! curl -sf --max-time 2 http://localhost:11434/ &>/dev/null; do
    ATTEMPT=$((ATTEMPT + 1))
    if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
        die "Ollama API not reachable after ${MAX_ATTEMPTS} attempts (localhost:11434)"
    fi
    printf "  ${DIM}Waiting for Ollama API... (%d/%d)${RESET}\r" "$ATTEMPT" "$MAX_ATTEMPTS"
    sleep 2
done
ok "Ollama API reachable (localhost:11434)"

# ── 4. Pull model ──────────────────────────────────────────────────
section "Pull model"
MODEL_LIST=$(docker exec ollama ollama list 2>/dev/null || echo "")
if echo "$MODEL_LIST" | grep -q "^${MODEL}"; then
    skip "${MODEL} downloaded"
else
    info "Pulling ${MODEL} (this may take a while)..."
    docker exec ollama ollama pull "$MODEL"
    ok "${MODEL} downloaded"
fi

# ── 5. Create alias ────────────────────────────────────────────────
section "Create alias"
MODEL_LIST=$(docker exec ollama ollama list 2>/dev/null || echo "")
if echo "$MODEL_LIST" | grep -q "^${ALIAS_NAME}"; then
    skip "${ALIAS_NAME} alias exists"
else
    docker exec ollama ollama cp "$MODEL" "$ALIAS_NAME"
    ok "Aliased ${MODEL} → ${ALIAS_NAME}"
fi

# ── 6. Shell alias ─────────────────────────────────────────────────
section "Shell alias"
ALIAS_LINE="alias claude-local='CLAUDE_CODE_USE_BEDROCK=0 ANTHROPIC_BASE_URL=http://localhost:11434/v1 ANTHROPIC_API_KEY=${DUMMY_KEY} claude'"

# Detect shell config file
SHELL_RC=""
if [[ -f "$HOME/.zshrc" ]]; then
    SHELL_RC="$HOME/.zshrc"
elif [[ -f "$HOME/.bashrc" ]]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [[ -n "$SHELL_RC" ]]; then
    if grep -q "alias claude-local=" "$SHELL_RC" 2>/dev/null; then
        skip "claude-local alias in ${SHELL_RC}"
    else
        echo "" >> "$SHELL_RC"
        echo "# claude-code-local" >> "$SHELL_RC"
        echo "$ALIAS_LINE" >> "$SHELL_RC"
        ok "Added claude-local alias to ${SHELL_RC}"
        info "Run: source ${SHELL_RC}  (or open a new terminal)"
    fi
else
    echo -e "  ${YELLOW}⚠${RESET} No .zshrc or .bashrc found. Add this manually:"
    echo ""
    echo "    $ALIAS_LINE"
    echo ""
fi

# ── 7. Seed Claude Code credentials ──────────────────────────────
section "Claude Code auth bypass"
CLAUDE_DIR="$HOME/.claude"
CREDS_FILE="$CLAUDE_DIR/.credentials.json"

if [[ -f "$CREDS_FILE" ]]; then
    skip "Credentials file exists (${CREDS_FILE})"
else
    mkdir -p "$CLAUDE_DIR"
    cat > "$CREDS_FILE" << CEOF
{
  "claudeAiOauth": {
    "accessToken": "dummy",
    "refreshToken": "dummy",
    "expiresAt": 0,
    "scopes": []
  }
}
CEOF
    chmod 600 "$CREDS_FILE"
    ok "Created dummy credentials (${CREDS_FILE})"
    info "This lets Claude Code skip the login prompt when using Ollama"
fi

# ── Done ───────────────────────────────────────────────────────────
section "Done"
echo -e "  ${GREEN}${BOLD}Setup complete!${RESET}"
echo ""
echo -e "  ${BOLD}Usage:${RESET}"
echo -e "    claude-local --model sonnet         ${DIM}# uses Ollama${RESET}"
echo -e "    claude --model sonnet               ${DIM}# uses normal setup (API/Bedrock)${RESET}"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "    make test                            ${DIM}# health check${RESET}"
echo -e "    make models                          ${DIM}# list models${RESET}"
echo -e "    make stop                            ${DIM}# stop Ollama${RESET}"
echo ""
