---
last_updated: 2026-05-09
---

# Operations / Troubleshooting

## Cron jobs (host VPS — НЕ devbox container)

```cron
# inbox-uploader — кожні 15 хвилин
*/15 * * * * /usr/bin/php /root/projects/zoom-uploader-distributed/vps/inbox-uploader.php >> /var/log/zoom-uploader.log 2>&1

# inbox-cleaner — раз на день о 04:00 Києва (~01-02 UTC)
0 1 * * * /root/projects/zoom-uploader-distributed/vps/inbox-cleaner.sh
```

Установити:
```bash
ssh -p 22 root@46.225.227.42
crontab -e
# додати рядки вище
```

## Логи

| Лог | Призначення |
|---|---|
| `/var/log/zoom-uploader.log` | uploader runs (start/end markers + errors + uploaded count) |
| `/var/log/zoom-cleaner.log` | cleanup runs (видалені файли + freed MB) |
| `/root/projects/zoom-uploader-distributed/vps/uploaded.log` | історія uploaded файлів (ledger: `<path>\|<videoId>\|<timestamp>`) |
| `C:\zoom-uploader\logs\push-YYYY-MM-DD.log` (на компі) | client push activity |

## Перевірка стану

```bash
# Скільки файлів у inbox зараз
find /root/zoom-inbox -type f \( -iname '*.mp4' -o -iname '*.m4a' \) | wc -l

# Розмір inbox
du -sh /root/zoom-inbox

# Останні uploaded
tail -10 /root/projects/zoom-uploader-distributed/vps/uploaded.log

# Запустити uploader manually
php /root/projects/zoom-uploader-distributed/vps/inbox-uploader.php
```

## Troubleshooting

### Файл застряг у inbox, не залився

1. Перевір `/var/log/zoom-uploader.log` — є record про спроби?
2. Якщо `quotaExceeded` — YouTube ліміт використано на сьогодні (10000 units = ~6 uploads). Дочекайся 00:00 PT (10:00 Києва).
3. Якщо `Token expired` — manually re-auth: на компі запусти `zoom_upload.php` interactively, скопіюй новий `token.json` на VPS.
4. Якщо файл reckent (mtime <2 хв) — uploader skip-ить. Чекай наступний cycle.

### Comp не push-ить

1. Manual run на компі: `powershell -File C:\zoom-uploader\push-agent.ps1`
2. Перевір лог `C:\zoom-uploader\logs\push-YYYY-MM-DD.log`
3. Перевір SSH:
   ```powershell
   ssh -p 2222 -i C:\zoom-uploader\.ssh\id_ed25519 root@46.225.227.42 'echo OK'
   ```
4. Якщо `Permission denied` — public key не у VPS authorized_keys. Re-додай.
5. Якщо rsync не знайдено — install cwRsync або через WSL.

### Disk fullу VPS

1. Швидкий cleanup усього старішого 1 дня:
   ```bash
   find /root/zoom-inbox -type f \( -iname '*.mp4' -o -iname '*.m4a' \) -mtime +1 -delete
   ```
2. Перевір `/root/backups/` — старі бекапи можна видаляти.
3. Pterodactyl volumes: `3c4202c1...` (старий MC1, 13 GB) — видалити якщо не потрібний.

### YouTube quota exhausted

10 000 units/день default × 1600 unit/upload = ~6 videos/day. Якщо більше:
1. Console Cloud → IAM & Admin → Quotas → "YouTube Data API v3" → Request quota increase
2. Або фільтрувати: великі recordings → manual upload, маленькі через бот

## Додавання нового компа

1. Скопіюй на нового компа:
   - `client-installer/install-zoom-uploader.ps1`
   - `client-installer/push-agent.ps1`
2. Запусти `install-zoom-uploader.ps1` як Administrator
3. Слідуй prompts (Zoom path, comp name)
4. Коли installer надрукує public key — зайди на VPS і додай у `~/.ssh/authorized_keys` з restriction (printed by installer)
5. Установіть mkdir для inbox: `ssh root@vps 'mkdir -p /root/zoom-inbox/<comp-name>'`
6. Підтверди у installer-i — він зробить тестовий push

## Видалення компа з системи

1. На компі: `Unregister-ScheduledTask -TaskName ZoomUploaderPush -Confirm:$false`
2. На компі: `Remove-Item -Recurse -Force C:\zoom-uploader`
3. На VPS: видали відповідний рядок з `~/.ssh/authorized_keys`
4. На VPS: `rm -rf /root/zoom-inbox/<comp-name>` (опційно — після того як останні файли залились)

## Безпека

- SSH keys ніколи не commitяться у repo (.gitignore у `client-installer/.ssh/`)
- Telegram bot token зашитий у скрипт (consistency з existing imgprep-bot, vira-consultant-bot — OK для приватного використання)
- Google API token (`token.json`) — на VPS у `/root/projects/php/youtube-uploader/`. Refresh-token живе довго, але потрібно мати access до compa для re-auth якщо token revoked.

## Disaster recovery

Якщо все впало — найважливіші артефакти для відновлення:
1. `/root/projects/php/youtube-uploader/credentials.json` + `token.json` — Google auth
2. `/root/projects/zoom-uploader-distributed/vps/uploaded.log` — щоб не дублювати uploads
3. `~/.ssh/authorized_keys` на VPS — щоб компи могли push-ити

Вони у `/root/projects/` mount, тому backup того самого що bambu-farm чи vira vault.
