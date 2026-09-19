#!/usr/bin/env python3
"""Minimal OpenAI-compatible embeddings server on fastembed (CPU, ~400 MB RSS).

Serves POST /v1/embeddings so OpenViking's `provider: openai` path can use a
local model: no API key, no money, no outbound traffic. Bound to loopback.
"""
from __future__ import annotations

import os
from typing import Any

from fastapi import FastAPI
from fastembed import TextEmbedding
from pydantic import BaseModel

MODEL_NAME = os.environ.get("EMBED_MODEL", "intfloat/multilingual-e5-small")
MAX_CHARS = int(os.environ.get("EMBED_MAX_CHARS", "8000"))

app = FastAPI()
_model = TextEmbedding(model_name=MODEL_NAME, threads=1)


class EmbedRequest(BaseModel):
    input: str | list[str]
    model: str | None = None


@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "model": MODEL_NAME}


@app.post("/v1/embeddings")
def embeddings(req: EmbedRequest) -> dict[str, Any]:
    texts = [req.input] if isinstance(req.input, str) else list(req.input)
    # The model truncates internally at its context window; cap the payload so a
    # huge chunk cannot stall the single worker thread.
    texts = [t[:MAX_CHARS] for t in texts]
    vectors = list(_model.embed(texts))
    data = [
        {"object": "embedding", "index": i, "embedding": [float(x) for x in vec]}
        for i, vec in enumerate(vectors)
    ]
    return {"object": "list", "data": data, "model": MODEL_NAME}
