---
status: in_progress
phase: design → implementation
created: 2026-05-09
owner: Олексій
---

# Zoom Uploader (distributed) — N-comps push → 1 VPS uploader → YouTube

> Розподілена альтернатива поточному `php/youtube-uploader/` що жил на одному компі. Кожен з робочих компів пушить нові Zoom-записи у спільний VPS-inbox; PHP-скрипт на VPS заливає на YouTube і робить TG-нотифікацію; auto-cleanup видаляє оброблене за 2 дні.

## Status

- ✅ **Design** (2026-05-09 — обрано Варіант H з 8 розглянутих, див. `docs/decisions.md`)
- ✅ **VPS infra** — cron `*/15 * * * *` (uploader) + `0 1 * * *` (cleaner) на host. Inbox перенесено у `/root/projects/zoom-inbox/` (shared mount між host і devbox); symlink `/root/zoom-inbox` для compat.
- ✅ **Code generated** (всі syntax-checked, UTF-8 BOM для Win compat):
  - `client-installer/install-zoom-uploader.ps1` — Windows self-installer
  - `client-installer/push-agent.ps1` — background hourly агент (scp-based)
  - `vps/inbox-uploader.php` — VPS-side processor
  - `vps/inbox-cleaner.sh` — TTL cleanup (2 дні)
- ✅ **First comp rolled out** (2026-05-09 12:05): `AsusTymur` (Windows ru-RU). End-to-end pipeline протестований — Zoom-record залився на YouTube за ~16 хв. Деталі: `reports/2026-05-09-rollout-asustymur.md`
- ⏳ **Pending**:
  - Re-copy виправленого `push-agent.ps1` на AsusTymur (PS 2.0 compat fix + .m4a виключення)
  - Rollout на решту компів

## Quick links

- [Architecture](docs/architecture.md)
- [Decisions / rating порівняних варіантів](docs/decisions.md)
- [Client install (Windows self-installer)](docs/installation-windows.md) — TBD
- [Operations / troubleshooting](docs/operations.md) — TBD
- [Initial design report](reports/2026-05-09-initial-design.md)

## Components

```
client-installer/   ← PowerShell self-installer для Windows-компа
                      (питає Zoom-folder path, генерує SSH key, копіює public на VPS,
                       ставить Task Scheduler, тест push)

scripts/            ← shared utilities (не client-side)

vps/                ← все що живе на VPS:
  inbox-uploader.php   — адаптація existing zoom_upload.php під inbox model
  inbox-cleaner.sh     — TTL-based cleanup (2 дні)

docs/               ← project documentation
reports/            ← session artifacts
```

## High-level flow

1. Comp (Windows) → PowerShell push-агент (Task Scheduler hourly):
   - scan Zoom-folder за новими файлами
   - rsync/scp у `vps:/root/zoom-inbox/<comp-name>/<file>.mp4` через SSH key
   - локальний marker що файл pushed (lock-файл або state.json)

2. VPS (cron щохвилину/щогодини):
   - `inbox-uploader.php` → scan `/root/zoom-inbox/`, upload на YouTube via Google API
   - ffmpeg → thumbnail у `/var/www/bajka.pp.ua/screenshots/`
   - TG ping через `@alexbothelp_bot`: thumbnail + YouTube link (без approve-кнопок)

3. VPS daily cron:
   - `inbox-cleaner.sh` — видаляє файли у inbox старіші 2 днів

## Critical paths / залежності

- Google API credentials (`credentials.json` + refresh token у `token.json`) — переноситься з existing youtube-uploader
- ffmpeg — install на VPS (`apt install ffmpeg`)
- SSH access на VPS port 2222 (devbox) — кожен комп має свій SSH key, public у `/root/.ssh/authorized_keys` на VPS
- Telegram `@alexbothelp_bot` token — той самий що у imgprep-bot, vira-consultant-bot
- Disk: 2 дні × ~10 records × ~200MB = ~4GB рекомендовано вільно у `/root/zoom-inbox/`
