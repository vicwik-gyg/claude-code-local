"""
Transparent logging proxy for Ollama's Anthropic-compatible API.

Sits between Claude Code and Ollama, logging all requests and responses
for learning and debugging. Enable with `make start-proxy`.
"""

import json
import os
import sys
from datetime import datetime

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse

OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://ollama:11434")
LOG_BODIES = os.getenv("LOG_BODIES", "true").lower() == "true"

app = FastAPI()

# Colors for terminal output
CYAN = "\033[96m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
DIM = "\033[2m"
RESET = "\033[0m"


def log(color: str, label: str, message: str) -> None:
    timestamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"{DIM}{timestamp}{RESET} {color}{label:>10}{RESET}  {message}", flush=True)


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy(request: Request, path: str):
    body = await request.body()
    url = f"{OLLAMA_HOST}/{path}"

    # Log request
    log(CYAN, "REQUEST", f"{request.method} /{path}")

    if LOG_BODIES and body:
        try:
            parsed = json.loads(body)
            model = parsed.get("model", "?")
            log(CYAN, "MODEL", model)
            if "messages" in parsed:
                msgs = parsed["messages"]
                log(CYAN, "MESSAGES", f"{len(msgs)} message(s)")
                for msg in msgs[-3:]:  # Show last 3 messages
                    role = msg.get("role", "?")
                    content = msg.get("content", "")
                    if isinstance(content, str):
                        preview = content[:120].replace("\n", " ")
                    else:
                        preview = f"[{len(content)} content blocks]"
                    log(DIM, role, preview)
            if parsed.get("stream"):
                log(YELLOW, "STREAM", "enabled")
        except (json.JSONDecodeError, AttributeError):
            log(DIM, "BODY", f"{len(body)} bytes (not JSON)")

    # Forward headers (drop host, add content-length)
    headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in ("host", "transfer-encoding")
    }

    async with httpx.AsyncClient(timeout=300.0) as client:
        upstream = await client.send(
            client.build_request(
                method=request.method,
                url=url,
                headers=headers,
                content=body,
            ),
            stream=True,
        )

        # Check if streaming response
        content_type = upstream.headers.get("content-type", "")
        is_streaming = "text/event-stream" in content_type

        if is_streaming:
            log(GREEN, "RESPONSE", f"{upstream.status_code} (streaming)")

            async def stream_and_log():
                async for chunk in upstream.aiter_bytes():
                    if LOG_BODIES:
                        text = chunk.decode("utf-8", errors="replace").strip()
                        for line in text.split("\n"):
                            if line.startswith("data: ") and line != "data: [DONE]":
                                try:
                                    data = json.loads(line[6:])
                                    # Extract text from various response formats
                                    if "delta" in data:
                                        delta = data["delta"]
                                        if "text" in delta:
                                            sys.stdout.write(delta["text"])
                                            sys.stdout.flush()
                                except json.JSONDecodeError:
                                    pass
                    yield chunk
                if LOG_BODIES:
                    print(flush=True)  # Newline after streamed text
                    log(GREEN, "DONE", "stream complete")

            return StreamingResponse(
                stream_and_log(),
                status_code=upstream.status_code,
                headers=dict(upstream.headers),
            )
        else:
            response_body = await upstream.aread()
            log(GREEN, "RESPONSE", f"{upstream.status_code} ({len(response_body)} bytes)")

            if LOG_BODIES and response_body:
                try:
                    parsed = json.loads(response_body)
                    if "content" in parsed:
                        for block in parsed["content"]:
                            if block.get("type") == "text":
                                preview = block["text"][:200].replace("\n", " ")
                                log(GREEN, "TEXT", preview)
                    elif "error" in parsed:
                        log(RED, "ERROR", json.dumps(parsed["error"]))
                except (json.JSONDecodeError, AttributeError):
                    pass

            return StreamingResponse(
                iter([response_body]),
                status_code=upstream.status_code,
                headers=dict(upstream.headers),
            )
