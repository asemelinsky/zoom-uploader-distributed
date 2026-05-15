#!/bin/bash
# inbox-cleaner.sh
# TTL-based cleanup для /root/zoom-inbox/.
# Видаляє відео-файли старіші TTL_DAYS — АЛЕ тільки якщо вони присутні у uploaded.log.
# Файли які не uploaded (напр. quota exhausted кілька днів поспіль) — зберігаються,
# щоб наступний cron run їх дозалив. Це prevent'ить data loss.
# Trigger: cron `0 1 * * *` (раз на день о 01:00 UTC = ~04:00 Київ).

set -euo pipefail

INBOX="/root/zoom-inbox"
UPLOADED="/root/projects/zoom-uploader-distributed/vps/uploaded.log"
LOG="/var/log/zoom-cleaner.log"
TTL_DAYS=2

mkdir -p "$INBOX"
touch "$LOG" "$UPLOADED"

log() {
  echo "[$(date '+%F %T')] $*" >> "$LOG"
}

log "═══ cleaner start ═══"

deleted_count=0
retained_count=0
total_size=0

while IFS= read -r -d '' f; do
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    if grep -qF "$f|" "$UPLOADED"; then
        rm -f "$f" && {
            log "  DEL: $f ($((size / 1024 / 1024)) MB)"
            deleted_count=$((deleted_count + 1))
            total_size=$((total_size + size))
        }
    else
        log "  RETAIN: $f ($((size / 1024 / 1024)) MB) — not in uploaded.log, awaiting upload retry"
        retained_count=$((retained_count + 1))
    fi
done < <(find "$INBOX" -type f \( -iname '*.mp4' -o -iname '*.m4a' -o -iname '*.mkv' -o -iname '*.mov' \) -mtime +"$TTL_DAYS" -print0)

# Видалити порожні sub-папки comp/<meeting>/ але НЕ сам comp/
find "$INBOX" -mindepth 2 -type d -empty -delete 2>/dev/null || true

log "Підсумок: видалено $deleted_count файлів ($((total_size / 1024 / 1024)) MB), retained $retained_count файлів (не uploaded)"
log "═══ cleaner end ═══"
