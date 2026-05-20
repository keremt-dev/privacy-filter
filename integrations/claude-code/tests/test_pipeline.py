"""Unit tests for the BIOES Viterbi decoder + mask_text utility.

These tests do NOT require the model to be downloaded; the pipeline's
_decode_bioes is a pure function over (offsets, labels, confidences).
"""
import pytest

from server.pipeline import Detection, PrivacyFilterPipeline, mask_text


def test_decode_single_b_e_span():
    text = "Hello Maya Chen!"
    # token boundaries: Hello, ' ', Maya, ' ', Chen, '!'
    offsets = [(0, 5), (6, 10), (11, 15), (15, 16)]
    labels = ["O", "B-private_person", "E-private_person", "O"]
    confs = [0.99, 0.97, 0.96, 0.99]
    out = PrivacyFilterPipeline._decode_bioes(text, offsets, labels, confs)
    assert len(out) == 1
    assert out[0].category == "private_person"
    assert out[0].text == "Maya Chen"
    assert 0.95 < out[0].confidence < 0.97


def test_decode_single_s_span():
    text = "Email me at jane@example.com today"
    offsets = [(0, 5), (6, 8), (9, 11), (12, 28), (29, 34)]
    labels = ["O", "O", "O", "S-private_email", "O"]
    confs = [0.99, 0.99, 0.99, 0.95, 0.99]
    out = PrivacyFilterPipeline._decode_bioes(text, offsets, labels, confs)
    assert len(out) == 1
    assert out[0].category == "private_email"
    assert out[0].text == "jane@example.com"


def test_decode_two_adjacent_spans():
    text = "Maya, sk-test-1"
    offsets = [(0, 4), (4, 5), (6, 15)]
    labels = ["S-private_person", "O", "S-secret"]
    confs = [0.95, 0.99, 0.99]
    out = PrivacyFilterPipeline._decode_bioes(text, offsets, labels, confs)
    assert len(out) == 2
    cats = sorted(d.category for d in out)
    assert cats == ["private_person", "secret"]


def test_decode_unknown_prefix_resets():
    text = "Foo Bar Baz"
    offsets = [(0, 3), (4, 7), (8, 11)]
    labels = ["B-private_person", "B-account_number", "O"]  # B without continuation
    confs = [0.9, 0.9, 0.9]
    out = PrivacyFilterPipeline._decode_bioes(text, offsets, labels, confs)
    # First B is flushed when a new B starts. Both get emitted as 1-token spans.
    assert len(out) == 2
    assert out[0].text == "Foo"
    assert out[1].text == "Bar"


def test_mask_text_simple():
    text = "Call Maya at jane@x.com"
    dets = [
        Detection("private_person", "Maya", 5, 9, 0.95),
        Detection("private_email", "jane@x.com", 13, 23, 0.95),
    ]
    masked = mask_text(text, dets)
    assert "Maya" not in masked
    assert "jane@x.com" not in masked
    assert "[PRIVATE_PERSON_1]" in masked
    assert "[PRIVATE_EMAIL_1]" in masked


def test_mask_text_reuses_token_for_same_value():
    text = "Maya called Maya again"
    dets = [
        Detection("private_person", "Maya", 0, 4, 0.95),
        Detection("private_person", "Maya", 12, 16, 0.95),
    ]
    masked = mask_text(text, dets)
    assert masked.count("[PRIVATE_PERSON_1]") == 2
    assert "[PRIVATE_PERSON_2]" not in masked


def test_mask_text_empty_detections():
    assert mask_text("hello", []) == "hello"


def test_mask_text_handles_overlapping_safely():
    # Two non-overlapping spans on same category, different values
    text = "Maya and Jordan"
    dets = [
        Detection("private_person", "Maya", 0, 4, 0.95),
        Detection("private_person", "Jordan", 9, 15, 0.95),
    ]
    masked = mask_text(text, dets)
    assert "[PRIVATE_PERSON_1]" in masked
    assert "[PRIVATE_PERSON_2]" in masked
