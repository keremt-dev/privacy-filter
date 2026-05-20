# NOTICE

This directory provides a **community integration** of the OpenAI Privacy Filter
with [Claude Code](https://claude.ai/code) via a `UserPromptSubmit` hook.

## Components

| Component | Origin | License |
|---|---|---|
| Upstream model + `opf/` library | [openai/privacy-filter](https://github.com/openai/privacy-filter) | Apache 2.0 |
| Hook scripts (`hook/`) | This integration | Apache 2.0 |
| Local FastAPI wrapper (`server/`) | This integration | Apache 2.0 |
| Policy + install scripts | This integration | Apache 2.0 |

## Provenance

- Original announcement: <https://openai.com/index/introducing-openai-privacy-filter/>
- Upstream model weights: HuggingFace `openai/privacy-filter`
- This integration is maintained in a fork; PR/issues against the
  `integrations/claude-code/` path are welcome.

## Technical scope

Claude Code's hook system can **block** prompts (`exit 2`) or **inject
additionalContext** for the LLM, but it cannot rewrite a prompt nor modify
the LLM's response. This integration therefore implements
**PII detection + selective blocking + audit logging**, not bidirectional
masking. For true two-way masking, an `ANTHROPIC_BASE_URL` proxy would be
required (out of scope for v1).
