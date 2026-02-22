.PHONY: start start-proxy start-gpu stop logs logs-proxy pull models alias shell clean status test

# Default model to pull (override with MODEL=xxx)
MODEL ?= qwen3-coder

## start: Start Ollama only (default, fastest)
start:
	docker compose up -d

## start-gpu: Start Ollama with NVIDIA GPU support
start-gpu:
	docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d

## start-proxy: Start Ollama + transparent logging proxy
start-proxy:
	docker compose --profile proxy up -d

## stop: Stop all services
stop:
	docker compose --profile proxy down

## status: Show running containers
status:
	docker compose ps

## logs: Tail Ollama logs
logs:
	docker compose logs -f ollama

## logs-proxy: Tail proxy logs (request/response traffic)
logs-proxy:
	docker compose logs -f proxy

## pull: Pull a model (usage: make pull MODEL=qwen3-coder)
pull:
	docker exec ollama ollama pull $(MODEL)

## models: List downloaded models
models:
	docker exec ollama ollama list

## alias: Create a model alias for Claude Code (usage: make alias FROM=qwen3:1.7b TO=claude-sonnet-4-6)
alias:
ifndef FROM
	$(error FROM is required. Usage: make alias FROM=qwen3:1.7b TO=claude-sonnet-4-6)
endif
ifndef TO
	$(error TO is required. Usage: make alias FROM=qwen3:1.7b TO=claude-sonnet-4-6)
endif
	docker exec ollama ollama cp $(FROM) $(TO)
	@echo "Aliased $(FROM) → $(TO)"

## shell: Open a shell in the Ollama container
shell:
	docker exec -it ollama bash

## test: Comprehensive health check and diagnostics (use MODEL=x to override)
test:
	@bash scripts/healthcheck.sh

## clean: Remove containers and volumes (deletes downloaded models!)
clean:
	docker compose --profile proxy down -v

## help: Show this help
help:
	@grep -E '^## ' Makefile | sed 's/## //' | column -t -s ':'
