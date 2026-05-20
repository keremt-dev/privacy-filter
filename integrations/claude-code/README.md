# Claude Code Hook — OpenAI Privacy Filter

OpenAI Privacy Filter (Apache 2.0) modelini Claude Code'a `UserPromptSubmit` hook'u olarak bağlayan, **proje-bazlı kurulabilen**, **politika yapılandırılabilir** bir entegrasyon.

> Bu klasör, bu repository fork'unda `openai/privacy-filter` üst projesinin **community integration**'ı olarak yer alır. Model ve ana kütüphane upstream'e aittir (Apache 2.0); buradaki entegrasyon kodu Apache 2.0 lisansı altında ek olarak sunulur. Path örneklerinde `$REPO` repo'nun klonlandığı dizini ifade eder.

## Ne Yapar?

Her Claude Code prompt'u yerel bir Privacy Filter sunucusundan geçer. PII tespit edildiğinde:

- **Block** (default: `secret`, `account_number`) → prompt iptal edilir (`exit 2`).
- **Warn** (default: `private_person`, `private_email`, `private_phone`, `private_address`) → Claude'a `additionalContext` ile uyarı enjekte edilir; audit log yazılır.
- **Ignore** (default: `private_url`, `private_date`) → görmezden gelinir.

Tüm tespitler `~/.claude-pii-audit/YYYY-MM-DD.jsonl` dosyasına yazılır. **Prompt içeriği log'a yazılmaz** — sadece SHA-256 hash + kategori + count + timestamp.

## Mimari Sınırı

Claude Code hook sistemi **prompt'u değiştiremez** ve **LLM response'unu intercept edemez**. Bu nedenle hook ile **gerçek iki-yönlü maskeleme imkansızdır**. Bu proje *detection + selective blocking + audit* yaklaşımıdır.

Gerçek "PII LLM'e hiç gitmesin + kullanıcı orijinali görsün" isteniyorsa → `ANTHROPIC_BASE_URL` ile lokal proxy yaklaşımı gerekir (bu repo'da yok, ileride v2).

## Kurulum

### Sunucuyu kur (tek seferlik)

```powershell
pwsh $REPO/integrations/claude-code/install/install-server.ps1
```

- venv oluşturur (`.venv/`)
- Python bağımlılıklarını kurar (transformers, torch, fastapi, uvicorn)
- HuggingFace'ten modeli indirir (~3 GB; lokal cache: `~/.cache/huggingface/`)

> Model ID varsayılan olarak `openai/privacy-filter`. Farklı bir checkpoint için: `$env:PRIVACY_FILTER_MODEL = "...";` sonra installer'ı çalıştır.

### Sunucuyu başlat

```powershell
# Foreground (geliştirme)
pwsh $REPO/integrations/claude-code/server/start-server.ps1

# Background (her oturum öncesi başlat)
pwsh $REPO/integrations/claude-code/server/start-server.ps1 -Background
```

Bağlanır: `http://127.0.0.1:8765` (sadece localhost).

### Bir projeye hook'u aktive et

```powershell
cd C:/kt/intellica-bva
pwsh $REPO/integrations/claude-code/install/install-project.ps1
```

Yapılan değişiklikler:
- `<proje>/.claude/settings.json` → `hooks.UserPromptSubmit` array'ine entry eklenir (mevcut hook'lar korunur)
- `<proje>/.claude/pii-policy.yaml` → default politika kopyalanır
- `<proje>/.gitignore` → audit dosyaları ve PID dosyaları eklenir

### Bir projeden kaldır

```powershell
pwsh $REPO/integrations/claude-code/install/uninstall.ps1 -ProjectPath C:/kt/intellica-bva
# -RemovePolicy bayrağı policy dosyasını da siler
```

## Politika Düzenleme

`<proje>/.claude/pii-policy.yaml` örneği:

```yaml
server:
  url: "http://127.0.0.1:8765"
  timeout_ms: 5000

categories:
  secret: block            # API key, parola
  account_number: block    # IBAN, kart, TC kimlik
  private_person: warn
  private_email: warn
  private_phone: warn
  private_address: warn
  private_url: ignore
  private_date: ignore

confidence_threshold: 0.85
min_prompt_length: 20      # bundan kısa promptlar atlanır
fail_open: true            # sunucu unreachable ise prompt geçer (false = blok)

audit:
  enabled: true
  dir: "~/.claude-pii-audit"
  rotate_days: 30
```

Daha agresif bir politika için `config/policy.example.yaml`'a bakın.

## Audit Log

Format: `~/.claude-pii-audit/YYYY-MM-DD.jsonl`, her satır bir JSON.

```jsonc
{
  "ts": "2026-05-20T14:32:11Z",
  "session": "abc123",
  "cwd": "C:/kt/intellica-bva",
  "action": "warn",                    // allow|warn|block|server_unavailable|error
  "categories": ["private_person", "private_email"],
  "detection_count": 3,
  "prompt_hash": "sha256:8f3a...",     // ham prompt asla kaydedilmez
  "prompt_chars": 142
}
```

## Test

```powershell
# Unit testler (pipeline + masking)
cd $REPO/integrations/claude-code
.\.venv\Scripts\Activate.ps1
pip install pytest
python -m pytest tests/test_pipeline.py -v

# Hook integration test (mock HTTP listener kullanır, gerçek modele ihtiyaç yok)
pwsh tests/test_hook.ps1
```

## Performans

| Donanım | İlk inference | Sonraki inference |
|---|---|---|
| CPU (Intel i7) | 2-5 sn | 200-500 ms |
| GPU (RTX 3060+) | ~1 sn | <100 ms |

`min_prompt_length: 20` ile kısa komutlar (`/clear`, `ls`, vb.) atlanır → ortalama gecikme düşer.

## Troubleshooting

**Hook çalışmıyor:**
- `pwsh -NoProfile -File $REPO/integrations/claude-code/hook/mask-pii-hook.ps1 < test.json` ile manuel test edin.
- Claude Code'un hangi PowerShell'i çağırdığını kontrol edin (`pwsh` PATH'te olmalı).

**Server unreachable:**
- `Invoke-RestMethod http://127.0.0.1:8765/health` ile elle kontrol edin.
- `.server.log` dosyasını inceleyin.
- 8765 portu başka bir process tarafından tutuluyor olabilir → port'u policy'de değiştirin ve `start-server.ps1 -Port 8766` ile başlatın.

**False positive ("Ali" → private_person):**
- `confidence_threshold`'u 0.85'ten 0.90+'a çıkarın.
- Veya o kategoriyi `ignore` yapın projeye özel policy'de.

**KVKK/uyumluluk:**
- Bu çözüm **uyumluluk sertifikası değildir**. Defense-in-depth katmanıdır.
- Warn modunda PII hala Anthropic'e gider. Tam izolasyon için proxy yaklaşımı (v2) gerekir.

## Lisans

Bu repo: MIT. Privacy Filter modeli: Apache 2.0 (OpenAI).

## Out of Scope (gelecek planlar)

- `ANTHROPIC_BASE_URL` proxy ile gerçek iki-yönlü maskeleme
- `PreToolUse.updatedInput` ile Read/Bash arg masking
- TR-özel fine-tune (TC kimlik, plaka, PNR, IBAN)
- Claude Desktop entegrasyonu (Desktop hook desteklemiyor)
