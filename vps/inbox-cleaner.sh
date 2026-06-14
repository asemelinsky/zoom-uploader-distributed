#!/bin/bash
# inbox-cleaner.sh v2 (2026-06-07)
#
# TTL-based cleanup для /root/projects/zoom-inbox/ (real path, не через symlink).
# Видаляє відео-файли старіші TTL_DAYS від моменту UPLOAD на YouTube.
# Файли НЕ у uploaded.log → зберігаються (не uploaded — захист від data loss).
# Trigger: cron `0 1 * * *` (раз на день о 01:00 UTC = ~04:00 Київ).
#
# Чому v2: v1 (інший repo) використовував `find /root/zoom-inbox` (symlink) +
# matching по full path. Це не працювало через 3 баги:
#   1. Symlink не traverse'ився find'ом → 0 файлів знайдено
#   2. Path mismatch: uploaded.log містив /root/zoom-inbox/... а find повертав
#      /root/projects/zoom-inbox/... — `grep -qF "$f|"` нічого не співпадав
#   3. Старі entries мали короткі names (videoXXX.mp4), нові — з prefix дати +
#      meeting title — повний шлях кожному різний
# v2 робить matching по basename + use `upload_timestamp` з ISO в 3-й колонці.

set -euo pipefail

INBOX="/root/projects/zoom-inbox"   # real path, без symlink
UPLOADED="/root/projects/zoom-uploader-distributed/vps/uploaded.log"
LOG="/var/log/zoom-cleaner.log"
TTL_DAYS=14

mkdir -p "$INBOX"
touch "$LOG" "$UPLOADED"

log() {
  echo "[$(date '+%F %T')] $*" >> "$LOG"
}

log "═══ cleaner v2 start (TTL=${TTL_DAYS}d, inbox=$INBOX) ═══"

# Build map: basename → upload_timestamp_epoch
declare -A UPLOADED_MAP
while IFS='|' read -r path youtube_id ts; do
  [ -z "$path" ] && continue
  bn=$(basename "$path")
  # ISO → epoch
  ts_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
  if [ "$ts_epoch" -gt 0 ]; then
    UPLOADED_MAP["$bn"]="$ts_epoch"
  fi
done < "$UPLOADED"

log "uploaded.log: ${#UPLOADED_MAP[@]} entries"

now=$(date +%s)
deleted_count=0
retained_uploaded=0
retained_pending=0
total_size=0

# Find усі video-файли
while IFS= read -r -d '' f; do
  bn=$(basename "$f")
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)

  if [ -n "${UPLOADED_MAP[$bn]:-}" ]; then
    # У uploaded.log є — перевіряємо age від upload_timestamp
    upload_ts=${UPLOADED_MAP[$bn]}
    age_days=$(( (now - upload_ts) / 86400 ))
    if [ "$age_days" -ge "$TTL_DAYS" ]; then
      if rm -f "$f"; then
        log "  DEL: $bn ($((size/1024/1024))MB, uploaded ${age_days}d ago)"
        deleted_count=$((deleted_count + 1))
        total_size=$((total_size + size))
      else
        log "  ERR: rm failed for $f"
      fi
    else
      log "  KEEP: $bn (uploaded ${age_days}d ago, < TTL)"
      retained_uploaded=$((retained_uploaded + 1))
    fi
  else
    log "  RETAIN: $bn ($((size/1024/1024))MB) — not in uploaded.log, awaiting upload"
    retained_pending=$((retained_pending + 1))
  fi
done < <(find "$INBOX" -type f \( -iname '*.mp4' -o -iname '*.m4a' -o -iname '*.mkv' -o -iname '*.mov' \) -print0)

# Видалити порожні sub-папки (meeting subdirs) але не корінь і не $INBOX/<host>/
find "$INBOX" -mindepth 3 -type d -empty -delete 2>/dev/null || true

total_mb=$((total_size / 1024 / 1024))
log "Підсумок: видалено $deleted_count файлів (${total_mb} MB), kept-fresh=$retained_uploaded, kept-pending=$retained_pending"
log "═══ cleaner v2 end ═══"
