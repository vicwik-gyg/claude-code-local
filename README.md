# claude-code-local

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with locally hosted LLMs via [Ollama](https://ollama.com). No API keys, no cloud, full transparency.

## Prerequisites

Install [Docker](https://docs.docker.com/get-docker/), [Node.js](https://nodejs.org/), and [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`). Verify with:

```bash
docker compose version    # v2+
claude --version          # Claude Code
make --version            # GNU Make
```

## Quickstart

```bash
git clone <this-repo> && cd claude-code-local
make start
make pull MODEL=qwen3:1.7b
make alias FROM=qwen3:1.7b TO=claude-sonnet-4-6

export ANTHROPIC_BASE_URL=http://localhost:11434/v1
export ANTHROPIC_API_KEY=sk-ant-api03-local-dummy-key-for-ollama-000000000000000000000000000000000000
export CLAUDE_CODE_USE_BEDROCK=0
claude --model sonnet
```

## How it works

Claude Code validates model names client-side — it only accepts Anthropic names like `claude-sonnet-4-6`. The Anthropic SDK appends `/messages` to the base URL (not `/v1/messages`). Three things make local Ollama work:

1. **`ANTHROPIC_BASE_URL=http://localhost:11434/v1`** — the `/v1` suffix is required so the SDK hits Ollama's `/v1/messages` endpoint
2. **Model aliasing** — `ollama cp qwen3:1.7b claude-sonnet-4-6` so Ollama responds to the name Claude Code sends
3. **Dummy API key** — format must be `sk-ant-api03-...` (Claude Code validates this) but the value is ignored by Ollama

Map local models to different Claude Code tiers:

| Alias | Anthropic model name | Example local model |
|-------|---------------------|---------------------|
| `sonnet` | `claude-sonnet-4-6` | qwen3-coder, deepseek-r1:14b |
| `haiku` | `claude-haiku-3-5-20241022` | qwen3:1.7b, llama3.1:8b |
| `opus` | `claude-opus-4-6` | qwen3-coder:30b |

## Shell setup

Add to `.bashrc` / `.zshrc`:

```bash
alias claude-local='CLAUDE_CODE_USE_BEDROCK=0 ANTHROPIC_BASE_URL=http://localhost:11434/v1 ANTHROPIC_API_KEY=sk-ant-api03-local-dummy-key-for-ollama-000000000000000000000000000000000000 claude'
```

Then `claude-local --model sonnet` uses Ollama, while `claude` continues using your normal setup (Bedrock, direct API, etc.). The alias overrides env vars only for that invocation. `CLAUDE_CODE_USE_BEDROCK=0` is only needed if you have Bedrock configured from a work setup.

## Commands

```bash
make start                                        # Start Ollama container
make stop                                         # Stop everything
make pull MODEL=qwen3-coder                       # Download a model
make models                                       # List downloaded models
make alias FROM=qwen3-coder TO=claude-sonnet-4-6  # Create alias for Claude Code
make test                                         # Comprehensive health check
make start-proxy                                  # Start Ollama + logging proxy
make logs-proxy                                   # Watch proxy traffic
make start-gpu                                    # Start with NVIDIA GPU support
make shell                                        # Open Ollama container shell
make clean                                        # Remove containers + volumes (deletes models!)
```

## Choosing a model

| Model | Size | RAM needed | Context | Tool use | Notes |
|-------|------|-----------|---------|----------|-------|
| `qwen3-coder` | 14B | ~10 GB | 32k | Good | Best balance for Claude Code |
| `qwen3-coder:30b` | 30B | ~20 GB | 32k | Good | Better quality, needs more RAM |
| `deepseek-r1:14b` | 14B | ~10 GB | 64k | Decent | Strong reasoning, slower |
| `llama3.1:8b` | 8B | ~5 GB | 128k | Limited | Small and fast |
| `qwen3:1.7b` | 1.7B | ~1.5 GB | 32k | Weak | Quick download to verify setup |

**Key differences from Claude:** Local models have smaller context windows (4k-32k vs 200k), slower inference (20-40 tok/sec for 7B on CPU), and worse tool use. RAM rule of thumb: parameters × 0.6 = GB needed (Q4 quantization). Docker on macOS has a fixed memory allocation — models must fit within it, not just host RAM.

### Extending context window

```bash
echo 'FROM qwen3-coder
PARAMETER num_ctx 65536' | docker exec -i ollama ollama create qwen3-coder-64k
```

See [Ollama Modelfile docs](https://github.com/ollama/ollama/blob/main/docs/modelfile.md) for more parameters.

### Transparent proxy

The proxy logs all Claude Code ↔ Ollama traffic with color-coded output:

```bash
make start-proxy && make logs-proxy
export ANTHROPIC_BASE_URL=http://localhost:4000/v1    # point at proxy instead
```

## Troubleshooting

### "400 The provided model identifier is invalid"

**The error message is misleading.** The problem is almost never the model name.

**Most likely cause: missing `/v1` in `ANTHROPIC_BASE_URL`.** The SDK appends only `/messages`, so without `/v1` it hits `localhost:11434/messages` — a nonexistent Ollama endpoint. Ollama returns a generic error that Claude Code surfaces as "invalid model identifier". We confirmed this by running an HTTP listener — no request arrived at all with the wrong URL.

```bash
# WRONG — hits /messages (doesn't exist)
export ANTHROPIC_BASE_URL=http://localhost:11434

# RIGHT — hits /v1/messages (Ollama's Anthropic endpoint)
export ANTHROPIC_BASE_URL=http://localhost:11434/v1
```

If the URL is correct, check that your model has an Anthropic alias (`make alias`) and that you're using `--model sonnet` not `--model qwen3:1.7b`.

### "403 Invalid API Key"

Multiple auth env vars can conflict silently:

| Env var | Effect |
|---------|--------|
| `ANTHROPIC_API_KEY` | What we need (format: `sk-ant-api03-...`) |
| `ANTHROPIC_AUTH_TOKEN` | **Conflicts** if both set — `unset` it |
| `CLAUDE_CODE_USE_BEDROCK=1` | **Ignores** `ANTHROPIC_BASE_URL` entirely — set to `0` |

Common cause: a work setup left `CLAUDE_CODE_USE_BEDROCK=1` or `ANTHROPIC_AUTH_TOKEN` in your shell profile.

### Responses seem too good for a local model

Claude Code may be routing to the cloud. Stop Ollama (`make stop`) and retry — if it still responds, check for `CLAUDE_CODE_USE_BEDROCK=1` in your shell profile.

### Other

- **Port conflict:** `lsof -i :11434` — stop any local Ollama instance
- **Pull fails:** Check disk space with `docker exec ollama df -h`
- **Proxy silent:** Ensure `ANTHROPIC_BASE_URL` points to port `4000`, not `11434`
