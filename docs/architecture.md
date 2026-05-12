---
last_updated: 2026-05-09
---

# Architecture

## Концептуальна діаграма

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ Comp1 (Windows) │     │ Comp2 (Windows) │     │ CompN ...       │
│                 │     │                 │     │                 │
│ D:\Zoom\        │     │ D:\Zoom\        │     │ <user's path>   │
│  ↓ scan hourly  │     │  ↓ scan hourly  │     │                 │
│ push-agent.ps1  │     │ push-agent.ps1  │     │                 │
│  ↓ SSH key      │     │  ↓ SSH key      │     │                 │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │ SSH/rsync over port 2222
                                 ↓
                  ┌──────────────────────────────────┐
                  │ VPS Hetzner — devbox container   │
                  │                                  │
                  │ /root/zoom-inbox/                │
                  │   ├─ comp1/<file>.mp4            │
                  │   ├─ comp2/<file>.mp4            │
                  │   └─ compN/...                   │
                  │                                  │
                  │ cron: */15 * * * * inbox-uploader│
                  │   • scan /root/zoom-inbox/       │
                  │   • google-api upload → YouTube  │
                  │   • ffmpeg thumbnail             │
                  │   • TG ping (notification only)  │
                  │                                  │
                  │ cron: 0 4 * * * inbox-cleaner    │
                  │   • find inbox/ -mtime +2 -delete│
                  └──────────────────────────────────┘
                                 │
                                 ↓
                  YouTube + Telegram + bajka.pp.ua/screenshots/
```

## Data flow per file (timeline)

| Час | Подія | Локація |
|---|---|---|
| T+0 | Zoom закінчує запис | `D:\Zoom\<meeting>.mp4` на компі |
| T+0...59min | comp у idle, файл лежить | local |
| T+H (hourly cron) | push-agent: scan, identify new file, push | comp → VPS via SSH/rsync |
| T+H (immediate) | VPS отримує файл | `/root/zoom-inbox/comp1/<meeting>.mp4` |
| T+H...+15min | VPS cron uploader спрацьовує | local processing |
| T+~5min | YouTube API upload | YouTube |
| T+~6min | ffmpeg thumbnail | `/var/www/bajka.pp.ua/screenshots/` |
| T+~6min | TG ping (`@alexbothelp_bot`) | user's TG |
| T+H+2days | Cleaner видаляє з inbox | VPS local |

Worst-case latency comp→YouTube: ~75 хв (59 для cron + 15 VPS-cycle + 5 upload).
Якщо потрібно швидше — змінити Task Scheduler trigger на 15-min інтервал.

## Components detalізовано

### Client-side: PowerShell push-agent

**Файл на компі:** `C:\zoom-uploader\push-agent.ps1`
**Trigger:** Task Scheduler — hourly (наприклад о 15-й хвилині)
**Залежності:** PowerShell 5+ (вбудовано у Windows 10+), ssh.exe (вбудовано у Windows 10+ build 1803+)

**Відповідальності:**
- Сканувати `<Zoom-folder>` за `.mp4` / `.m4a` файлами
- Перевірити які з них вже push'ені (state-файл `pushed.json`)
- Push нові через `scp -P 2222 -i <ssh-key>` у `root@46.225.227.42:/root/zoom-inbox/<comp-name>/`
- Mark як pushed у state-файлі
- Лог у `C:\zoom-uploader\logs\push-YYYY-MM-DD.log`
- (Optional) TG ping якщо upload впав 3+ рази підряд

**Конфігурація:** `C:\zoom-uploader\config.json`
```json
{
  "comp_name": "lenovo-home",
  "zoom_folder": "D:\\Zoom",
  "vps_host": "46.225.227.42",
  "vps_port": 2222,
  "vps_user": "root",
  "vps_inbox_path": "/root/zoom-inbox/lenovo-home",
  "ssh_key_path": "C:\\zoom-uploader\\.ssh\\id_ed25519",
  "log_dir": "C:\\zoom-uploader\\logs",
  "state_file": "C:\\zoom-uploader\\pushed.json"
}
```

### Client-side: Self-installer

**Файл на компі (тимчасово при install):** `install-zoom-uploader.ps1`

**Що питає у user:**
- Шлях до Zoom-folder (default `D:\Zoom`)
- Унікальна назва компа (`comp_name`) — для inbox sub-folder

**Що робить:**
1. Створює `C:\zoom-uploader\` структуру
2. Generates SSH key (ed25519) у `C:\zoom-uploader\.ssh\id_ed25519`
3. Друкує public key і запитує user-а скопіювати його у VPS authorized_keys (або через SSH password — interactive)
4. Записує `config.json`
5. Копіює `push-agent.ps1` з template
6. Створює Task Scheduler entry
7. Робить тестовий push (1 файл або dummy.txt)
8. Якщо все ОК — повідомляє success + посилання на logs

### VPS-side: inbox-uploader.php

**Файл:** `/root/projects/zoom-uploader-distributed/vps/inbox-uploader.php`
**Trigger:** cron `*/15 * * * *`

**Адаптація з existing `php/youtube-uploader/zoom_upload.php`:**
- Параметризувати `$zoomDir` як array (для кожного comp sub-dir у inbox)
- Прибрати локальний SFTP→VPS thumbnail upload — на VPS він local, просто copy
- Залишити Google API upload, ffmpeg, TG notification, log

**Логіка:**
```php
$inbox = '/root/zoom-inbox';
foreach (glob("$inbox/*", GLOB_ONLYDIR) as $compDir) {
    $compName = basename($compDir);
    foreach (glob("$compDir/*.{mp4,m4a}", GLOB_BRACE) as $videoFile) {
        if (already_uploaded($videoFile)) continue;
        $youtubeId = upload_to_youtube($videoFile, ...);
        $thumbPath = generate_thumbnail($videoFile, ...);
        copy_thumbnail_to_screenshots($thumbPath);
        send_tg_notification($compName, $videoFile, $youtubeId, $thumbPath);
        log_uploaded($videoFile, $youtubeId);
        // НЕ видаляємо одразу — залишаємо для cleaner
    }
}
```

### VPS-side: inbox-cleaner.sh

**Файл:** `/root/projects/zoom-uploader-distributed/vps/inbox-cleaner.sh`
**Trigger:** cron `0 4 * * *` (раз на день о 4 ранку)

```bash
find /root/zoom-inbox -type f \( -name '*.mp4' -o -name '*.m4a' \) -mtime +2 -delete
find /root/zoom-inbox -type d -empty -delete
echo "[$(date '+%F %T')] cleaned files >2d" >> /var/log/zoom-cleaner.log
```

## Auth model

- **На компі:** SSH private key у `C:\zoom-uploader\.ssh\id_ed25519` (chmod-equivalent NTFS permissions: read-only тільки для current user).
- **На VPS:** public key у `/root/.ssh/authorized_keys` з restriction:
  ```
  command="rsync --server -avz . /root/zoom-inbox/<comp-name>/",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA... comp1@zoom-uploader
  ```
  (Restricted command — комп може тільки rsync у свою sub-папку, нічого більше.)

## Failure modes

| Сценарій | Поведінка |
|---|---|
| Comp offline під час cron | Push fails, state не оновлюється; наступного cycle спробує знову |
| VPS offline | Push fails з SSH error; comp lock-файл не оновлюється; retry next hour |
| Файл уже залитий (case crash) | `already_uploaded()` перевіряє `uploaded.log` за hash/filename → skip |
| YouTube API quota exhausted | PHP логує помилку, файл залишається у inbox; cleaner не видалить (mtime old enough? — risk!); потрібен fallback warning через TG |
| ffmpeg не встановлено | PHP логує, TG ping без thumbnail (URL тільки YouTube) |
| SSH key compromised | Видалити public key з authorized_keys, regenerate новий через installer |

## Що НЕ підтримується (out of scope)

- Resume для частково завантажених файлів (rsync handles partial transfers — added)
- Encryption at rest (Zoom-records не encrypted у inbox; Tailscale encrypts in transit, SSH теж)
- Multi-account YouTube (один Google account для всіх uploads)
- Webhook на YouTube events (notification тільки через TG ping наш)
- Mac/Linux client (тільки Windows у MVP)
