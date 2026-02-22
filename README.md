# claude-code-local

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with locally hosted LLMs via [Ollama](https://ollama.com). No API keys, no cloud, full transparency.

Ollama v0.14.0+ natively supports the Anthropic Messages API, so Claude Code can talk to it directly. An optional logging proxy lets you inspect all traffic for learning and debugging.

## Prerequisites

You need three things: Docker, Node.js (for Claude Code), and `make`.

### macOS

```bash
# Docker Desktop
brew install --cask docker

# Node.js (if not installed)
brew install node

# Claude Code
npm install -g @anthropic-ai/claude-code

# make is pre-installed with Xcode Command Line Tools
xcode-select --install  # if not already installed
```

### Ubuntu / Debian

```bash
# Docker
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Allow running Docker without sudo
sudo usermod -aG docker $USER
newgrp docker  # or log out and back in

# Node.js (via NodeSource)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# Claude Code
npm install -g @anthropic-ai/claude-code

# make
sudo apt-get install -y make
```

### Fedora / RHEL

```bash
# Docker
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl start docker && sudo systemctl enable docker
sudo usermod -aG docker $USER

# Node.js
sudo dnf install -y nodejs

# Claude Code
npm install -g @anthropic-ai/claude-code

# make
sudo dnf install -y make
```

### Verify installation

```bash
docker --version          # Docker 24+
docker compose version    # Compose v2+
node --version            # Node 18+
claude --version          # Claude Code
make --version            # GNU Make
```

## Quickstart

```bash
git clone <this-repo> && cd claude-code-local
make start
make pull MODEL=qwen3:1.7b                          # download a model (~1.4 GB)
make alias FROM=qwen3:1.7b TO=claude-sonnet-4-6     # alias it to an Anthropic model name

# connect Claude Code to Ollama
export ANTHROPIC_BASE_URL=http://localhost:11434/v1
export ANTHROPIC_API_KEY=sk-ant-api03-local-dummy-key-for-ollama-000000000000000000000000000000000000
export CLAUDE_CODE_USE_BEDROCK=0
claude --model sonnet
```

> **Why the alias?** Claude Code validates model names client-side and only accepts Anthropic model names (e.g., `claude-sonnet-4-6`). By aliasing your local model, Ollama responds to the name Claude Code sends.

## Usage

### Start/stop Ollama

```bash
make start          # Start Ollama container
make stop           # Stop everything
make status         # Show running containers
```

### Manage models

```bash
make pull MODEL=qwen3-coder                          # Download a model
make pull MODEL=deepseek-r1                           # Download another model
make models                                           # List downloaded models
make alias FROM=qwen3-coder TO=claude-sonnet-4-6      # Alias for Claude Code
```

**Important:** Claude Code only accepts Anthropic model names. After pulling a model, create an alias so Ollama responds to the name Claude Code expects:

```bash
# Map your local model to an Anthropic model name
make alias FROM=qwen3-coder TO=claude-sonnet-4-6

# Now Claude Code can use it via the "sonnet" alias
claude --model sonnet
```

You can map different local models to different Anthropic tiers:

| Claude Code alias | Anthropic model name | Example local model |
|-------------------|---------------------|---------------------|
| `sonnet` | `claude-sonnet-4-6` | qwen3-coder, deepseek-r1:14b |
| `haiku` | `claude-haiku-3-5-20241022` | qwen3:1.7b, llama3.1:8b |
| `opus` | `claude-opus-4-6` | qwen3-coder:30b |

### Optional: transparent proxy

The proxy sits between Claude Code and Ollama, logging all requests and responses with color-coded terminal output. Useful for understanding how Claude Code communicates with the backend.

```bash
make start-proxy     # Start Ollama + proxy
make logs-proxy      # Watch the traffic

# Point Claude Code at the proxy instead
export ANTHROPIC_BASE_URL=http://localhost:4000/v1
claude --model sonnet
```

### GPU support (NVIDIA)

If you have an NVIDIA GPU with the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) installed:

```bash
make start-gpu
```

Or manually:

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
```

## How it works

```
Claude Code                     Ollama (Docker)
    │                               │
    │ --model sonnet                │
    │     ↓                         │
    │ resolves to                   │
    │ "claude-sonnet-4-6"           │
    │     ↓                         │
    │ POST /v1/messages             │
    │ {"model":"claude-sonnet-4-6"} │
    │ ─────────────────────────────►│
    │                               │ looks up "claude-sonnet-4-6"
    │                               │ → alias for qwen3:1.7b
    │                               │ → runs inference
    │◄───────────────────────────── │
    │ response                      │
```

Three things make this work:

1. **`ANTHROPIC_BASE_URL=http://localhost:11434/v1`** — redirects Claude Code to Ollama instead of the Anthropic API. The `/v1` suffix is required because Claude Code appends only `/messages` to the base URL.
2. **Model aliasing** — `ollama cp qwen3:1.7b claude-sonnet-4-6` creates an alias so Ollama responds to the Anthropic model name that Claude Code sends.
3. **Dummy API key** — Claude Code validates the key format (`sk-ant-api03-...`) but Ollama ignores the value entirely.

## Choosing a model

Local models differ significantly from Claude. Keep these tradeoffs in mind:

### Recommended models

| Model | Size | RAM needed | Context | Tool use | Notes |
|-------|------|-----------|---------|----------|-------|
| `qwen3-coder` | 14B | ~10 GB | 32k | Good | Best balance for Claude Code usage |
| `qwen3-coder:30b` | 30B | ~20 GB | 32k | Good | Better quality, needs more RAM |
| `deepseek-r1:14b` | 14B | ~10 GB | 64k | Decent | Strong reasoning, slower |
| `codellama:13b` | 13B | ~8 GB | 16k | Limited | Fast, but weaker tool use |
| `llama3.1:8b` | 8B | ~5 GB | 128k | Limited | Small and fast, good for testing |
| `qwen3:1.7b` | 1.7B | ~1.5 GB | 32k | Weak | Quick download to verify setup works |

### Key differences from Claude

**Context window** — Claude has 200k tokens. Local models default to 4k-32k. Claude Code sends file contents, tool results, and conversation history with every call, so you'll hit limits faster. Increase via custom Modelfiles (see `models/README.md`), but more context = more RAM and slower inference.

**Speed** — CPU inference is slow. Expect 20-40 tokens/sec for a 7B model, 5-15 tokens/sec for 30B+. Each Claude Code action (read, edit, bash) is a separate API roundtrip. GPU helps significantly.

**Tool use** — Claude Code relies on structured tool calling (read files, edit, bash). Local models vary in how well they handle this. Some will malform JSON or ignore tools. Qwen3-coder and DeepSeek are among the better options.

**Quality** — Claude Code's prompting is optimized for Claude. Local models will produce worse results on complex multi-step tasks. This is a learning/experimentation project, not a production replacement.

**RAM** — Rough rule: model parameters × 0.6 = GB of RAM needed (for Q4 quantization). A 14B model needs ~10 GB free, a 70B model needs ~42 GB. If your machine doesn't have enough RAM, Ollama will fall back to CPU swap and become extremely slow.

### Extending context window

Create a custom Modelfile to increase context (uses more RAM):

```bash
# Create a 64k context variant
echo 'FROM qwen3-coder
PARAMETER num_ctx 65536' > models/Modelfile.qwen3-coder-64k

docker exec -i ollama ollama create qwen3-coder-64k < models/Modelfile.qwen3-coder-64k
claude-local --model qwen3-coder-64k
```

See `models/README.md` for more Modelfile options.

## Shell setup

Add to your `.bashrc` / `.zshrc` for convenience:

```bash
# Claude Code with local Ollama
alias claude-local='CLAUDE_CODE_USE_BEDROCK=0 ANTHROPIC_BASE_URL=http://localhost:11434/v1 ANTHROPIC_API_KEY=sk-ant-api03-local-dummy-key-for-ollama-000000000000000000000000000000000000 claude'
```

Then: `claude-local --model sonnet`

> **Note:** The `CLAUDE_CODE_USE_BEDROCK=0` override is only needed if you have Bedrock configured in your shell (e.g., from a work setup). The API key must be in Anthropic's format (`sk-ant-api03-...`) but can be any value — Ollama ignores it.

### Switching between local and cloud

The `claude-local` alias overrides env vars only for that invocation. Your regular `claude` command is unaffected and continues to use whatever you had before (Bedrock, direct API, etc.):

```bash
claude-local --model sonnet    # → local Ollama
claude --model sonnet          # → real Anthropic API (your normal setup)
```

If you set the env vars with `export` instead of the alias, unset them to switch back:

```bash
unset ANTHROPIC_BASE_URL
unset ANTHROPIC_API_KEY
unset CLAUDE_CODE_USE_BEDROCK
claude --model sonnet          # → back to normal
```

## Project structure

```
.
├── docker-compose.yml      # Ollama + optional proxy
├── docker-compose.gpu.yml  # GPU override (NVIDIA)
├── Makefile                # All commands: make help
├── proxy/
│   ├── proxy.py            # Logging proxy (~100 lines)
│   ├── Dockerfile
│   └── requirements.txt
├── scripts/
│   └── healthcheck.sh      # Comprehensive diagnostics (make test)
├── models/
│   └── README.md           # Custom Modelfile guide
├── .env.example            # Config template
└── README.md               # This file
```

## Health check

Run `make test` for a comprehensive diagnostic of the entire project:

```bash
make test
```

This checks: project files, Docker status, container state, network ports, Ollama version, downloaded models and their sizes, shell environment variables, .env config, Claude Code installation, a live API smoke test (sends a real prompt), proxy passthrough, container resource usage, and disk space. Each item reports pass/warn/fail with actionable fix instructions.

## Troubleshooting

### "400 The provided model identifier is invalid"

This is the most common error and **the message is misleading**. Despite what it says, the problem is almost never the model name. Here's what's actually happening and how to fix it:

**Most likely cause: missing `/v1` in the base URL.**

The Anthropic SDK appends only `/messages` to `ANTHROPIC_BASE_URL`. So:

| Base URL | SDK sends to | Result |
|----------|-------------|--------|
| `http://localhost:11434/v1` | `http://localhost:11434/v1/messages` | Works — this is Ollama's Anthropic-compatible endpoint |
| `http://localhost:11434` | `http://localhost:11434/messages` | **Fails** — Ollama has no `/messages` endpoint, returns a generic error that Claude Code surfaces as "invalid model identifier" |

This is the #1 gotcha. The fix:

```bash
# WRONG
export ANTHROPIC_BASE_URL=http://localhost:11434

# RIGHT
export ANTHROPIC_BASE_URL=http://localhost:11434/v1
```

**Why it's so confusing:** When you get this error, your first instinct is to fix the model name. You might try renaming models, creating aliases, using different formats — none of it helps because the model name was never the problem. The request was going to the wrong URL path entirely. We verified this by setting up an HTTP listener on the correct port — with the wrong base URL, no request ever arrived, confirming the SDK was hitting a dead endpoint.

If you've confirmed the URL is correct, also check:
- **Model must have an Anthropic alias**: `make alias FROM=qwen3:1.7b TO=claude-sonnet-4-6`
- **Use Claude Code's model aliases**: `claude --model sonnet` (NOT `claude --model qwen3:1.7b`)

### "403 Invalid API Key"

This error also has a non-obvious cause. Claude Code supports multiple authentication mechanisms, and they can conflict:

| Env var | Purpose | Effect |
|---------|---------|--------|
| `ANTHROPIC_API_KEY` | Direct API authentication | What we need for Ollama (format: `sk-ant-api03-...`) |
| `ANTHROPIC_AUTH_TOKEN` | Alternative auth (e.g., LiteLLM) | **Conflicts** with `ANTHROPIC_API_KEY` if both are set |
| `CLAUDE_CODE_USE_BEDROCK` | AWS Bedrock routing | If set to `1`, Claude Code ignores `ANTHROPIC_BASE_URL` entirely |

The most common scenario: you have a work setup with Bedrock (`CLAUDE_CODE_USE_BEDROCK=1`) or an existing `ANTHROPIC_AUTH_TOKEN` in your shell profile. These silently override the local Ollama settings.

Fix:
```bash
unset ANTHROPIC_AUTH_TOKEN              # remove conflicting auth
export CLAUDE_CODE_USE_BEDROCK=0        # disable Bedrock routing
export ANTHROPIC_API_KEY=sk-ant-api03-local-dummy-key-for-ollama-000000000000000000000000000000000000
```

The API key value can be anything — Ollama ignores it — but the format must start with `sk-ant-api03-` to pass Claude Code's client-side validation.

### Claude Code uses the real API instead of Ollama

If responses seem too good for your local model, Claude Code may be routing to the cloud. This can happen silently if Bedrock or subscription auth takes precedence over the base URL.

Diagnosis:
1. Stop Ollama: `make stop`
2. Try `claude --model sonnet -p "hello"` — if it still responds, it's not using Ollama
3. Check for `CLAUDE_CODE_USE_BEDROCK=1` in your shell profile

Fix: ensure `CLAUDE_CODE_USE_BEDROCK=0` is set, and that no other auth mechanism is active.

### Other issues

**Ollama container won't start**
Check if port 11434 is already in use: `lsof -i :11434`. Stop any local Ollama instance first.

**Model pull fails**
Ensure you have enough disk space. Models range from 2GB to 70GB+. Check with `docker exec ollama df -h`.

**Streaming doesn't work**
Some models or Ollama versions may have issues with streaming. Try updating Ollama: `docker compose pull ollama && make start`.

**Proxy not showing logs**
Make sure `ANTHROPIC_BASE_URL` points to `http://localhost:4000/v1` (not 11434) when using the proxy.

## Useful commands

```bash
make help           # Show all available commands
make test           # Comprehensive health check
make shell          # Open shell in Ollama container
make alias FROM=qwen3:1.7b TO=claude-sonnet-4-6  # Create model alias
make clean          # Remove containers + volumes (deletes models!)
```
