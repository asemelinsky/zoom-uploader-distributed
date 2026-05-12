---
last_updated: 2026-05-09
---

# Windows client — установка

## Prerequisites

- **Windows 10 build 1803+** або **Windows 11** — для вбудованого OpenSSH (`ssh-keygen.exe`, `ssh.exe`, `scp.exe`).
- **rsync для Windows** — НЕ вбудований. Варіанти:
  - **cwRsync** — https://itefix.net/cwrsync (free version OK)
  - **WSL2** — `wsl --install` → Ubuntu → `sudo apt install rsync openssh-client`
  - У installer ssмоції pad: попередньо встановити cwRsync і додати у PATH
- **PowerShell 5+** — вбудовано у всі підтримувані Windows
- **Адмін права** — для Task Scheduler

## Кроки

1. **Скопіюй на новий комп** (через USB / OneDrive / GitHub):
   - `install-zoom-uploader.ps1`
   - `push-agent.ps1`
   
   Поклади у будь-яку папку (наприклад `C:\Users\<you>\Downloads\zoom-installer\`).

2. **Запусти PowerShell як Administrator:**
   - Win+X → Windows PowerShell (Admin)
   - Або: правий клік на `install-zoom-uploader.ps1` → Run with PowerShell as Administrator

3. **Встанови ExecutionPolicy** (один раз на комп):
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

4. **Запусти installer:**
   ```powershell
   cd C:\Users\<you>\Downloads\zoom-installer\
   .\install-zoom-uploader.ps1
   ```

5. **Відповіси на питання:**
   - **Zoom-folder path** — куди Zoom зберігає recordings (default `D:\Zoom`)
   - **Comp name** — унікальна назва (default = ім'я компа). Цей name стає sub-папкою у `/root/zoom-inbox/`.

6. **Installer згенерує SSH key** і надрукує текст для додавання у VPS authorized_keys. **Скопіюй це у VPS** (інструкція у виводі).

7. **На VPS:**
   ```bash
   ssh -p 2222 root@46.225.227.42
   mkdir -p /root/zoom-inbox/<comp-name>
   nano /root/.ssh/authorized_keys
   # paste the line з виводу installer-а
   chmod 600 /root/.ssh/authorized_keys
   ```

8. **Натиснеш Enter** у installer-i — він зробить тестовий push.

9. Якщо тест успішний — installer створить Task Scheduler entry `ZoomUploaderPush` (hourly) і завершиться.

## Manual run (для перевірки)

```powershell
powershell -File "C:\zoom-uploader\push-agent.ps1"
```

Або через Task Scheduler GUI: `taskschd.msc` → знайди `ZoomUploaderPush` → Run.

## Логи

```powershell
Get-Content "C:\zoom-uploader\logs\push-$(Get-Date -Format 'yyyy-MM-dd').log" -Tail 20
```

## Що installer створює

```
C:\zoom-uploader\
├── config.json           ← налаштування цього компа
├── pushed.json           ← state — які файли вже push-ені (size+mtime)
├── push-agent.ps1        ← background-агент
├── logs\
│   └── push-YYYY-MM-DD.log
└── .ssh\
    ├── id_ed25519        ← private key (NTFS read-only для current user)
    └── id_ed25519.pub    ← public (копіюється у VPS authorized_keys)
```

## Видалення

```powershell
# Як Admin
Unregister-ScheduledTask -TaskName ZoomUploaderPush -Confirm:$false
Remove-Item -Recurse -Force C:\zoom-uploader
```

На VPS видалити рядок з `/root/.ssh/authorized_keys` для цього компа і `/root/zoom-inbox/<comp-name>`.

## Troubleshooting (Windows-специфічні)

### "ssh-keygen.exe: command not found"

Windows 10 Pre-1803 — установи OpenSSH:
- Settings → Apps → Optional Features → Add a feature → "OpenSSH Client" → Install

### "rsync.exe: command not found"

Установи cwRsync:
1. https://itefix.net/cwrsync — download free version
2. Розпакуй у `C:\Program Files\cwRsync\`
3. Додай у PATH: `setx PATH "%PATH%;C:\Program Files\cwRsync\bin"` (як Admin)
4. Перезапусти PowerShell

### "Task Scheduler — task не запускається"

Якщо Task Scheduler entry створено але push не відбувається:
- Перевір через `taskschd.msc` → правий клік на task → History
- Часта проблема: "User must be logged on" — у нашого installer-а ми ставимо `LogonType S4U` (працює навіть коли user logged off, при підключенні до мережі)
- Якщо комп у sleep — Task Scheduler НЕ wake-it. Recommend power settings: "Never sleep" або принаймні allow tasks to wake comp.
