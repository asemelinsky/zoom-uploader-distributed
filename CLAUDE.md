# Zoom Uploader Distributed — robота над цим проектом

Якщо ти Claude Code session з cwd тут — це проект **distributed Zoom-to-YouTube pipeline**. Read README.md перш ніж починати.

## Контекст одним рядком

Замість одного компа який заливає Zoom-records, маємо N компів які push-ять у спільний VPS-inbox; PHP-скрипт на VPS обробляє і заливає на YouTube.

## Структура

```
/root/projects/zoom-uploader-distributed/
├── README.md              ← overview, status
├── CLAUDE.md              ← (this file) — onboarding
├── docs/
│   ├── architecture.md    ← компоненти, flow, failure modes
│   ├── decisions.md       ← чому обрали Варіант H (з порівняльним рейтингом)
│   ├── installation-windows.md  ← TBD при implement
│   └── operations.md      ← TBD при implement
├── client-installer/      ← PowerShell self-installer + push-agent.ps1
├── vps/                   ← inbox-uploader.php + inbox-cleaner.sh
├── scripts/               ← shared helpers
└── reports/               ← session-end snapshots
```

## Дотичні проекти

- `php/youtube-uploader/` — **existing** youtube-uploader (single-comp version). Зразок для адаптації.
- `bambu-farm/` — Tailscale-bridge архітектура. Reference якщо вирішимо Варіант B (Tailscale + push) у майбутньому.
- `imgprep-bot` — TG bot з callback-кнопками (`@alexbothelp_bot`). Reference якщо додамо approve-UI.

## Worflow для нової сесії

1. **Read README.md + docs/architecture.md** щоб зрозуміти стан.
2. **Перевір phase / status** у README.md. Якщо `in_progress` — продовжуй з backlog.
3. **Логуй прогрес** у `reports/<date>-<topic>.md` після значущих кроків.
4. **Update README.md status** при переході phases.

## Конвенції

- Українською у docs та комітах.
- LF line endings (`.gitattributes`) — особливо для PowerShell файлів які мисти на Windows.
- Confidentials (SSH keys, tokens) — НЕ commitити. Use `.gitignore`.
- Cross-link reports у README.md "Quick links" якщо вони стають reference.

## Залежності зовнішні

- VPS Hetzner 46.225.227.42 — devbox container, port 2222
- `@alexbothelp_bot` — TG нотифікації
- Google API credentials (з existing `php/youtube-uploader/credentials.json`)
- ffmpeg на VPS

## Important caveats

- **Disk:** `/` на VPS зайнятий 93%. Inbox може жерти ~10GB. Перевір free space перед heavy testing.
- **YouTube quota:** 10 000 units/день default, 1600 per upload → max ~6/day. Monitor usage.
- **SSH command-restriction:** authorized_keys для compN має `command="rsync --server -avz . /root/zoom-inbox/<compN>/"` — інакше комп може робити arbitrary commands на VPS. Це critical security захист.
