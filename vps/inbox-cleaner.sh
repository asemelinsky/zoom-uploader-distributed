#!/bin/bash
# inbox-cleaner.sh
# TTL-based cleanup для /root/zoom-inbox/.
# Видаляє відео-файли старіші 2 днів. Не торкається uploaded.log і нещодавніх.
# Trigger: cron `0 4 * * *` (раз на день о 4 ранку Києва = 02:00 UTC взимку, 01:00 UTC влітку).

set -euo pipefail

INBOX="/root/zoom-inbox"
LOG="/var/log/zoom-cleaner.log"
TTL_DAYS=2

mkdir -p "$INBOX"
touch "$LOG"

log() {
  echo "[$(date '+%F %T')] $*" >> "$LOG"
}

log "═══ cleaner start ═══"

# Знаходимо відео-файли старіші TTL
deleted_count=0
total_size=0

while IFS= read -r -d '' f; do
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    total_size=$((total_size + size))
    rm -f "$f" && {
        log "  DEL: $f ($((size / 1024 / 1024)) MB)"
        deleted_count=$((deleted_count + 1))
    }
done < <(find "$INBOX" -type f \( -iname '*.mp4' -o -iname '*.m4a' -o -iname '*.mkv' -o -iname '*.mov' \) -mtime +"$TTL_DAYS" -print0)

# Видалити порожні sub-папки comp/<meeting>/ але НЕ сам comp/
find "$INBOX" -mindepth 2 -type d -empty -delete 2>/dev/null || true

log "Підсумок: видалено $deleted_count файлів, вивільнено $((total_size / 1024 / 1024)) MB"
log "═══ cleaner end ═══"
