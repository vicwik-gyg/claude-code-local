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
make setup
```

This single command will: start Ollama, pull the default model (`qwen3-coder`), create the `claude-sonnet-4-6` alias, and add a `claude-local` shell alias. Override the model with `MODEL=x make setup`.

Once done:

```bash
claude-local --model sonnet
```

<details>
<summary>Manual setup (step-by-step)</summary>

```bash
make start
make pull MODEL=qwen3:1.7b
make alias FROM=qwen3:1.7b TO=claude-sonnet-4-6

export ANTHROPIC_BASE_URL=http://localhost:11434
export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_API_KEY=
export CLAUDE_CODE_USE_BEDROCK=0
claude --model sonnet
```

</details>

## First-time Claude Code setup

No Anthropic account or subscription is needed. The `claude-local` alias sets `ANTHROPIC_AUTH_TOKEN=ollama` and empties `ANTHROPIC_API_KEY`, which tells Claude Code to skip its login flow and use the base URL directly.

If Claude Code still prompts for login, run `claude /logout` first to clear any cached credentials, then try again.

## How it works

Claude Code validates model names client-side — it only accepts Anthropic names like `claude-sonnet-4-6`. Three things make local Ollama work:

1. **`ANTHROPIC_BASE_URL=http://localhost:11434`** — points Claude Code at local Ollama
2. **`ANTHROPIC_AUTH_TOKEN=ollama`** + **`ANTHROPIC_API_KEY=`** (empty) — bypasses the login flow entirely
3. **Model aliasing** — `ollama cp qwen3:1.7b claude-sonnet-4-6` so Ollama responds to the name Claude Code sends

Map local models to different Claude Code tiers:

| Alias | Anthropic model name | Example local model |
|-------|---------------------|---------------------|
| `sonnet` | `claude-sonnet-4-6` | qwen3-coder, deepseek-r1:14b |
| `haiku` | `claude-haiku-3-5-20241022` | qwen3:1.7b, llama3.1:8b |
| `opus` | `claude-opus-4-6` | qwen3-coder:30b |

## Shell setup

Add to `.bashrc` / `.zshrc`:

```bash
alias claude-local='CLAUDE_CODE_USE_BEDROCK=0 ANTHROPIC_BASE_URL=http://localhost:11434 ANTHROPIC_AUTH_TOKEN=ollama ANTHROPIC_API_KEY= claude'
```

Then `claude-local --model sonnet` uses Ollama, while `claude` continues using your normal setup (Bedrock, direct API, etc.). The alias overrides env vars only for that invocation. `CLAUDE_CODE_USE_BEDROCK=0` is only needed if you have Bedrock configured from a work setup.

## Commands

```bash
make setup                                        # One-command setup (first time)
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
export ANTHROPIC_BASE_URL=http://localhost:4000    # point at proxy instead
```

## Troubleshooting

### "400 The provided model identifier is invalid"

**The error message is misleading.** The problem is almost never the model name. Check that your model has an Anthropic alias (`make alias`) and that you're using `--model sonnet` not `--model qwen3:1.7b`.

### Login prompt keeps appearing

Claude Code may have cached credentials from a previous login. Clear them:

```bash
claude /logout
```

Then ensure your alias uses the correct env vars — `ANTHROPIC_AUTH_TOKEN=ollama` and `ANTHROPIC_API_KEY=` (empty). The empty API key is critical; if it's set to any value, Claude Code tries to authenticate with Anthropic.

### Auth env var conflicts

Multiple auth env vars can conflict silently:

| Env var | Required value | Effect if wrong |
|---------|---------------|-----------------|
| `ANTHROPIC_AUTH_TOKEN` | `ollama` | Must be set — this is what bypasses login |
| `ANTHROPIC_API_KEY` | empty | If set, Claude Code tries to authenticate with Anthropic |
| `CLAUDE_CODE_USE_BEDROCK` | `0` | If `1`, ignores `ANTHROPIC_BASE_URL` entirely |

Common cause: a work setup left `CLAUDE_CODE_USE_BEDROCK=1` or `ANTHROPIC_API_KEY` in your shell profile.

### Responses seem too good for a local model

Claude Code may be routing to the cloud. Stop Ollama (`make stop`) and retry — if it still responds, check for `CLAUDE_CODE_USE_BEDROCK=1` in your shell profile.

### Other

- **Port conflict:** `lsof -i :11434` — stop any local Ollama instance
- **Pull fails:** Check disk space with `docker exec ollama df -h`
- **Proxy silent:** Ensure `ANTHROPIC_BASE_URL` points to port `4000`, not `11434`
