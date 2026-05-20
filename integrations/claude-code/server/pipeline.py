"""Privacy Filter pipeline: tokenize -> forward -> BIOES Viterbi span decode."""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

import torch
from transformers import AutoModelForTokenClassification, AutoTokenizer

CATEGORIES = [
    "private_person",
    "private_address",
    "private_email",
    "private_phone",
    "private_url",
    "private_date",
    "account_number",
    "secret",
]

MODEL_ID = os.environ.get("PRIVACY_FILTER_MODEL", "openai/privacy-filter")


@dataclass
class Detection:
    category: str
    text: str
    start: int
    end: int
    confidence: float

    def to_dict(self) -> dict:
        return {
            "category": self.category,
            "text": self.text,
            "start": self.start,
            "end": self.end,
            "confidence": round(self.confidence, 4),
        }


class PrivacyFilterPipeline:
    """Loads the model once, exposes detect()."""

    def __init__(self, model_id: str = MODEL_ID, device: Optional[str] = None):
        self.model_id = model_id
        self.device = device or ("cuda" if torch.cuda.is_available() else "cpu")
        self.tokenizer = AutoTokenizer.from_pretrained(model_id)
        self.model = AutoModelForTokenClassification.from_pretrained(model_id)
        self.model.to(self.device)
        self.model.eval()
        self.id2label = self.model.config.id2label

    @torch.inference_mode()
    def detect(self, text: str) -> list[Detection]:
        if not text:
            return []
        enc = self.tokenizer(
            text,
            return_offsets_mapping=True,
            truncation=True,
            max_length=getattr(self.model.config, "max_position_embeddings", 4096),
            return_tensors="pt",
        )
        offsets = enc.pop("offset_mapping")[0].tolist()
        inputs = {k: v.to(self.device) for k, v in enc.items()}
        logits = self.model(**inputs).logits[0]
        probs = torch.softmax(logits, dim=-1)
        conf, pred = probs.max(dim=-1)
        labels = [self.id2label[int(i)] for i in pred.tolist()]
        confidences = conf.tolist()
        return self._decode_bioes(text, offsets, labels, confidences)

    @staticmethod
    def _decode_bioes(
        text: str,
        offsets: list[tuple[int, int]],
        labels: list[str],
        confidences: list[float],
    ) -> list[Detection]:
        """Group BIOES-tagged tokens into spans."""
        detections: list[Detection] = []
        current_cat: Optional[str] = None
        current_start: Optional[int] = None
        current_end: Optional[int] = None
        current_confs: list[float] = []

        def flush():
            nonlocal current_cat, current_start, current_end, current_confs
            if current_cat and current_start is not None and current_end is not None:
                detections.append(
                    Detection(
                        category=current_cat,
                        text=text[current_start:current_end],
                        start=current_start,
                        end=current_end,
                        confidence=sum(current_confs) / max(len(current_confs), 1),
                    )
                )
            current_cat = None
            current_start = None
            current_end = None
            current_confs = []

        for (off_start, off_end), label, c in zip(offsets, labels, confidences):
            if off_start == 0 and off_end == 0:
                continue
            if label == "O" or label is None:
                flush()
                continue
            if "-" in label:
                prefix, cat = label.split("-", 1)
            else:
                prefix, cat = "I", label
            if prefix in ("B", "S"):
                flush()
                current_cat = cat
                current_start = off_start
                current_end = off_end
                current_confs = [c]
                if prefix == "S":
                    flush()
            elif prefix in ("I", "E") and current_cat == cat:
                current_end = off_end
                current_confs.append(c)
                if prefix == "E":
                    flush()
            else:
                flush()
                current_cat = cat
                current_start = off_start
                current_end = off_end
                current_confs = [c]

        flush()
        return detections


def mask_text(text: str, detections: list[Detection]) -> str:
    """Replace each detection with [CATEGORY_N] indexed token (deterministic per run)."""
    if not detections:
        return text
    counters: dict[str, int] = {}
    seen: dict[tuple[str, str], str] = {}
    spans = sorted(detections, key=lambda d: d.start, reverse=True)
    out = text
    for d in spans:
        key = (d.category, out[d.start:d.end])
        token = seen.get(key)
        if not token:
            counters[d.category] = counters.get(d.category, 0) + 1
            token = f"[{d.category.upper()}_{counters[d.category]}]"
            seen[key] = token
        out = out[:d.start] + token + out[d.end:]
    return out
