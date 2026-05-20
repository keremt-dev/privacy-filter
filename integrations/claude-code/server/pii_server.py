"""FastAPI server exposing /detect and /health for the Privacy Filter."""
from __future__ import annotations

import logging
from typing import Optional

from fastapi import FastAPI
from pydantic import BaseModel, Field

from pipeline import PrivacyFilterPipeline, mask_text

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("pii-server")

app = FastAPI(title="OpenAI Privacy Filter — Local")
_pipeline: Optional[PrivacyFilterPipeline] = None


class DetectRequest(BaseModel):
    text: str = Field(..., description="Text to scan for PII")
    return_masked: bool = Field(True, description="Include masked version in response")


class DetectionDTO(BaseModel):
    category: str
    text: str
    start: int
    end: int
    confidence: float


class DetectResponse(BaseModel):
    detections: list[DetectionDTO]
    masked: Optional[str] = None
    char_count: int


@app.on_event("startup")
def _load() -> None:
    global _pipeline
    log.info("Loading Privacy Filter model...")
    _pipeline = PrivacyFilterPipeline()
    log.info("Model ready on device=%s", _pipeline.device)


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok" if _pipeline else "loading",
        "model_loaded": _pipeline is not None,
        "device": _pipeline.device if _pipeline else None,
        "model_id": _pipeline.model_id if _pipeline else None,
    }


@app.post("/detect", response_model=DetectResponse)
def detect(req: DetectRequest) -> DetectResponse:
    assert _pipeline is not None, "Model not loaded"
    detections = _pipeline.detect(req.text)
    masked = mask_text(req.text, detections) if req.return_masked else None
    return DetectResponse(
        detections=[DetectionDTO(**d.to_dict()) for d in detections],
        masked=masked,
        char_count=len(req.text),
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="info")
