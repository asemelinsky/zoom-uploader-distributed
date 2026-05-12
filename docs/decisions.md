---
last_updated: 2026-05-09
---

# Design Decisions

## D-01: Push (не pull) як основний transport

**Status:** ✓ accepted

**Контекст:** comp може бути offline у будь-який момент, особливо мобільні / робочі ноути.

**Decision:** push з компа → VPS, не VPS-pull через SMB/NFS mount.

**Чому:**
- Comp ініціює — push happens коли comp онлайн і має файли
- Pull-модель залишала VPS у позиції "запитувати" — якщо комп offline, треба retry-cycle
- Push proactively справляється з offline-windows: cron на компі retry-яне коли comp прокинеться

## D-02: SSH (не Tailscale) для transport

**Status:** ✓ accepted

**Decision:** native SSH/scp/rsync на VPS port 2222 (devbox) через SSH key. Без Tailscale.

**Чому:**
- Tailscale на кожен комп = додатковий setup і maintenance
- SSH вже працює, port 2222 публічний
- SSH key restriction (`command="rsync --server..."`) — security обмеження не гірша за Tailscale ACL
- Один менш daemon на компі

**Trade-off:** SSH йде через public internet (encrypted). Tailscale це private mesh. Для нашого scale прийнятно.

## D-03: Auto-cleanup (не approve кнопки)

**Status:** ✓ accepted

**Decision:** замість approve-UI з TG-кнопками — простий cron-cleaner видаляє файли з inbox старіші 2 днів.

**Чому:**
- Менше рухомих частин (нема callback handler, нема pending state)
- Юзер усе одно перевіряє через TG notification з YouTube link
- Якщо щось не так — встигне сказати протягом 1-2 днів
- Якщо потрібно зберегти конкретний файл — manual `mv` поза inbox

**Trade-off:** менший контроль над auto-delete. Якщо user хоче save конкретний файл — мусить пам'ятати manually move.

## D-04: Self-installer style (як Кодомандри Prism)

**Status:** ✓ accepted

**Decision:** PowerShell self-installer що питає Zoom-path у user, генерує SSH key, копіює public на VPS.

**Чому:**
- Zero-touch setup для новуго компа — copy-paste 1 ps1, запустиш, відповіси на питання
- Familiar pattern (Кодомандри installer для Prism Launcher)
- Менше ручної конфігурації — скрипт сам пише config.json, Task Scheduler XML

## D-05: Storage TTL = 2 дні

**Status:** ✓ accepted

**Decision:** cleanup runs щодоби, видаляє inbox-файли з mtime > 2 days.

**Чому 2 (не 1, не 7):**
- 1 день — занадто agressive, мало вікна для review
- 7 днів — занадто м'яко, накопичується ~7×Zoom-records (~7-14 GB) на 93%-зайнятому диску
- 2 дні — балансом, дає вікно reaction і disk-friendly

## Decision matrix — порівняні варіанти

(Шкала 1-10. Бал = (Setup ease + Maintenance + Resilience + Switch-cost) / 4)

| Варіант | Setup | Maint | Resilience | Switch-cost (новий комп) | **Бал** |
|---|---|---|---|---|---|
| **A**: Tailscale + SMB pull | 5 | 6 | 6 | 5 | **6** |
| **B**: Tailscale + push-rsync | 6 | 7 | 8 | 6 | **7** |
| **C**: Cloud-staging (Google Drive) | 8 | 8 | 9 | 7 | **8** |
| **D**: Syncthing | 5 | 6 | 7 | 5 | **5** |
| **E**: Distributed (uploader на кожен) | 4 | 4 | 7 | 4 | **5** |
| **F**: Telegram-channel inbox | 9 | 8 | 5 | 8 | **3 (50MB ліміт killer)** |
| **G**: Cloudflare Tunnel | 5 | 5 | 6 | 5 | **5** |
| ⭐ **H**: SSH push + VPS PHP cron + cleanup | 8 | 9 | 9 | 9 | **9** |

**Чому H ⭐:**
- Найменше friction для нового компа (self-installer + SSH key)
- Не треба Tailscale на компах
- PHP скрипт як зараз, тільки inbox-loop вираз з folder param
- Auto-cleanup замість approve-UI — простіше
- Familiar pattern (як Prism для Кодомандрів)

**Чому НЕ C (Google Drive):**
- C мав 8 балів — теж дуже добре. Програв через зайвий round-trip (comp→Drive→VPS) і Drive storage usage.
- Якщо цей варіант провалиться у production — C є сильним fallback.
