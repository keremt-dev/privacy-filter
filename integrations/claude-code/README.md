# Claude Code Hook — OpenAI Privacy Filter

Wires the OpenAI Privacy Filter (Apache 2.0) into [Claude Code](https://claude.ai/code) as a
`UserPromptSubmit` hook so that every user prompt is scanned for PII before it leaves your
machine for the Anthropic API.

> This folder is a **community integration** living inside a fork of `openai/privacy-filter`.
> The model and the `opf/` library belong to OpenAI (Apache 2.0). The integration code here is
> released under the same license. In path examples below, `$REPO` is the directory where this
> repository is cloned (e.g. `C:/kt/privacy-filter`).

---

## What It Does

Every prompt you type into Claude Code is intercepted by a local hook that calls a small
FastAPI server running the Privacy Filter model. Each detection is then evaluated against a
**policy file**:

| Action      | Default categories                                                        | Behavior                                                              |
|-------------|---------------------------------------------------------------------------|-----------------------------------------------------------------------|
| **block**   | `secret`, `account_number`                                                | Hook exits `2`. Prompt is cancelled before it reaches Anthropic.      |
| **warn**    | `private_person`, `private_email`, `private_phone`, `private_address`     | Hook injects an `additionalContext` warning so Claude is told.        |
| **ignore**  | `private_url`, `private_date`                                             | Detection is recorded in the audit log only.                          |

All decisions are appended to `~/.claude-pii-audit/YYYY-MM-DD.jsonl`. **The raw prompt is
never written to disk** — only a SHA-256 hash plus categories, counts, and timestamp.

---

## Architectural Limit (read before installing)

Claude Code hooks **cannot rewrite a prompt** and **cannot intercept the LLM response**.
This integration therefore implements **detection + selective blocking + audit logging**, not
true bidirectional masking. PII in a `warn` category still reaches the Anthropic API.

If you need "PII never reaches the LLM but is visible in the output", that requires an
`ANTHROPIC_BASE_URL` proxy approach — out of scope for v1.

---

## Requirements

| Component         | Minimum                                                   |
|-------------------|-----------------------------------------------------------|
| OS                | Windows 10/11 (PowerShell 7+). Linux/macOS straightforward to port. |
| PowerShell        | `pwsh` 7.0+ on `PATH`                                     |
| Python            | 3.10+                                                     |
| Disk              | ~3 GB for the Privacy Filter model weights                |
| Memory            | 4 GB RAM minimum (CPU). GPU optional.                     |
| Claude Code       | Any recent version that supports `hooks` in `settings.json` |

---

## Installation

The installation is two-staged: **server is per-machine, hook is per-project**.

### 1. Install the server (one-time, per machine)

From the repo root:

```powershell
pwsh $REPO/integrations/claude-code/install/install-server.ps1
```

This script:

1. Creates a Python venv at `$REPO/integrations/claude-code/.venv/`
2. Installs dependencies (`transformers`, `torch`, `fastapi`, `uvicorn`, `pydantic`)
3. Downloads the model from HuggingFace (default: `openai/privacy-filter`, ~3 GB) into
   `~/.cache/huggingface/`

To use a different model checkpoint:

```powershell
$env:PRIVACY_FILTER_MODEL = "your-org/your-checkpoint"
pwsh $REPO/integrations/claude-code/install/install-server.ps1
```

### 2. Activate the hook in a project (per project)

```powershell
cd C:/path/to/your-project
pwsh $REPO/integrations/claude-code/install/install-project.ps1
```

This script:

- Creates `<project>/.claude/` if missing
- Merges a hook entry into `<project>/.claude/settings.json` under
  `hooks.UserPromptSubmit` (existing hooks are preserved)
- Copies the default policy file to `<project>/.claude/pii-policy.yaml` (kept if it already
  exists; pass `-Force` to overwrite)
- Appends a few entries to `<project>/.gitignore` (audit files, server PID/log)
- Runs a health check against `http://127.0.0.1:8765`

### 3. Uninstall (per project)

```powershell
pwsh $REPO/integrations/claude-code/install/uninstall.ps1 -ProjectPath C:/path/to/your-project
# Add -RemovePolicy to also delete .claude/pii-policy.yaml
```

---

## Running

### Start the server

```powershell
# Foreground (useful while developing)
pwsh $REPO/integrations/claude-code/server/start-server.ps1

# Background (recommended for daily use; PID written to $REPO/.server.pid)
pwsh $REPO/integrations/claude-code/server/start-server.ps1 -Background
```

The server binds to `http://127.0.0.1:8765` (localhost only — never exposed to the network).

Cold start takes 5–10 s while the model loads; subsequent requests are 100–500 ms on CPU.

### Use Claude Code normally

Just open Claude Code inside an installed project — the hook runs automatically on every
prompt. Three outcomes are possible:

1. **Clean prompt** → hook exits silently, Claude responds as usual.
2. **PII in a `warn` category** → Claude receives an extra `additionalContext` message such as:
   > "[PII WARNING] This user prompt was flagged for: private_person (1), private_email (1).
   > Avoid echoing this sensitive data back; refer to it abstractly."
3. **PII in a `block` category** → prompt is cancelled with an error message like:
   > `PII blocked: secret category detected (confidence >= 0.85). Policy: ...`

You will see the rejection in the Claude Code terminal; nothing is sent to Anthropic.

### Verify it is working

```powershell
# Health
Invoke-RestMethod http://127.0.0.1:8765/health
# → status=ok, model_loaded=True, device=cpu|cuda

# Direct detection probe
$body = @{ text = "Email me at jane@example.com please" } | ConvertTo-Json
Invoke-RestMethod http://127.0.0.1:8765/detect -Method POST `
    -ContentType "application/json" -Body $body
# → detections=[{ category=private_email, ... }], masked="Email me at [PRIVATE_EMAIL_1] please"
```

---

## Configuration

The per-project policy lives at `<project>/.claude/pii-policy.yaml`. A minimal example:

```yaml
server:
  url: "http://127.0.0.1:8765"
  timeout_ms: 5000

categories:
  secret: block            # API keys, passwords, tokens
  account_number: block    # IBAN, card numbers, national IDs
  private_person: warn
  private_email: warn
  private_phone: warn
  private_address: warn
  private_url: ignore
  private_date: ignore

confidence_threshold: 0.85   # detections below this are dropped
min_prompt_length: 20        # prompts shorter than this are skipped (latency)
fail_open: true              # if server is unreachable, allow the prompt through

audit:
  enabled: true
  dir: "~/.claude-pii-audit"
  rotate_days: 30
```

For an aggressive setup that blocks every category, see
[`config/policy.example.yaml`](config/policy.example.yaml).

Policy resolution order:

1. `<project>/.claude/pii-policy.yaml` (per-project)
2. `$REPO/integrations/claude-code/config/policy.default.yaml` (fallback)

---

## Audit Log

Path: `~/.claude-pii-audit/YYYY-MM-DD.jsonl`. One JSON object per line:

```jsonc
{
  "ts": "2026-05-20T14:32:11Z",
  "session": "abc123",
  "cwd": "C:/path/to/project",
  "action": "warn",                       // allow|warn|block|server_unavailable|error
  "categories": ["private_person", "private_email"],
  "detection_count": 3,
  "prompt_hash": "sha256:8f3a...",        // raw prompt is NEVER stored
  "prompt_chars": 142
}
```

Files older than `audit.rotate_days` are pruned opportunistically on each hook invocation.

---

## Testing

Two layers — neither requires the model to be downloaded:

```powershell
# Pure-function unit tests (BIOES decoder + token masking)
cd $REPO/integrations/claude-code
.\.venv\Scripts\Activate.ps1
pip install pytest
python -m pytest tests/test_pipeline.py -v

# Hook integration test (mocks the HTTP server; covers clean/warn/block paths)
pwsh tests/test_hook.ps1
```

`tests/fixtures/tr_samples.txt` ships Turkish PII samples (IBAN, national ID, phone, card,
secrets) you can use for manual end-to-end checks once the real model is loaded.

---

## Performance

| Hardware              | First inference | Steady-state inference |
|-----------------------|-----------------|------------------------|
| CPU (Intel i7, 8c)    | 2–5 s           | 200–500 ms             |
| GPU (RTX 3060+)       | ~1 s            | < 100 ms               |

The `min_prompt_length: 20` setting skips short commands (`/clear`, `ls`, etc.) so most
keystroke-level prompts incur zero overhead.

---

## Troubleshooting

**Hook does not appear to run**
- Manually invoke it: `Get-Content test.json | pwsh -NoProfile -File $REPO/integrations/claude-code/hook/mask-pii-hook.ps1`
- Ensure `pwsh` 7+ is on `PATH` (Claude Code launches the hook command verbatim).
- Inspect `<project>/.claude/settings.json` to confirm the entry was merged.

**Server unreachable**
- `Invoke-RestMethod http://127.0.0.1:8765/health` to probe directly.
- Check `$REPO/.server.log` for stack traces.
- Port 8765 already in use? Start with `-Port 8766` and update `server.url` in the policy.

**False positives (e.g. common given names flagged as `private_person`)**
- Raise `confidence_threshold` from `0.85` toward `0.92+`.
- Or set the offending category to `ignore` in the project policy.

**Compliance disclaimer**
This integration is a defense-in-depth layer, not a compliance certification. In `warn`
mode the original PII still reaches the Anthropic API. For true isolation, a proxy-based
architecture is required (out of scope here).

---

## What's Next

Possible follow-ups, none of which are implemented yet:

- `ANTHROPIC_BASE_URL` proxy for full bidirectional masking
- `PreToolUse.updatedInput` to mask arguments passed to `Read` / `Bash`
- Domain fine-tunes (e.g. Turkish national ID, license plates, PNR codes)
- Claude Desktop support (Desktop has no hook system; needs the proxy approach)

---

## License & Attribution

- This integration: **Apache 2.0** (same as upstream).
- Upstream model and library: **OpenAI Privacy Filter** — <https://github.com/openai/privacy-filter>
- Announcement: <https://openai.com/index/introducing-openai-privacy-filter/>

See [`NOTICE.md`](NOTICE.md) for full provenance.
