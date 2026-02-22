# Custom Modelfiles

Ollama supports [Modelfiles](https://github.com/ollama/ollama/blob/main/docs/modelfile.md) for customizing model behavior.

## Example: Extended context window

Create a file called `Modelfile.qwen3-coder-64k`:

```
FROM qwen3-coder
PARAMETER num_ctx 65536
```

Build and use it:

```bash
docker exec ollama ollama create qwen3-coder-64k -f /dev/stdin < models/Modelfile.qwen3-coder-64k
claude --model qwen3-coder-64k
```

## Common parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `num_ctx` | Context window size (tokens) | Model-dependent |
| `temperature` | Randomness (0.0 = deterministic) | 0.8 |
| `top_p` | Nucleus sampling threshold | 0.9 |
| `num_gpu` | Number of GPU layers to offload | Auto |

## Tips

- Larger `num_ctx` uses more memory. Start with the default and increase if needed.
- Lower `temperature` (0.1-0.3) tends to work better for code generation.
- Place Modelfiles in this directory for version control.
