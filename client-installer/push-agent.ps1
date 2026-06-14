# push-agent.ps1
# Background agent який раз на годину сканує Zoom-folder і push-ить нові файли у VPS-inbox.
# Запускається Task Scheduler (див. install-zoom-uploader.ps1).
# Manual run: powershell -File C:\zoom-uploader\push-agent.ps1

#Requires -Version 5.0

$ErrorActionPreference = 'Continue'  # don't crash on individual file errors

$installDir = "C:\zoom-uploader"
$configPath = "$installDir\config.json"

if (-not (Test-Path $configPath)) {
    Write-Host "config.json не знайдено: $configPath. Запусти install-zoom-uploader.ps1 спершу."
    exit 1
}

$cfg = Get-Content $configPath -Raw | ConvertFrom-Json

# === Log ===
$logFile = "$($cfg.log_dir)\push-$(Get-Date -Format 'yyyy-MM-dd').log"
function Log($msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

Log "═══ push-agent start (comp=$($cfg.comp_name)) ═══"

# === State (які файли вже push-ені) ===
$state = @{}
if (Test-Path $cfg.state_file) {
    try {
        $state = Get-Content $cfg.state_file -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        Log "WARN: state file парсе fail, починаю з порожнього: $_"
    }
}
if ($null -eq $state) { $state = @{} }

# === VPS-side dedup (захист від data loss якщо local state пропав) ===
# Тягнемо uploaded.log з VPS і будуємо HashSet basenames. Якщо файл уже залитий на
# YouTube колись (запис у uploaded.log) — НЕ пушимо повторно, навіть якщо локальний
# state не знає про нього. Це root-cause fix для "перезаливання 38GB старих файлів"
# що траплялось коли cleaner видалив з VPS inbox через TTL, а local state на ноуті
# пропав/зламався.
$vpsUploadedBasenames = $null
try {
    $tmpUploaded = Join-Path $env:TEMP "vps-uploaded-$(Get-Date -Format 'yyyyMMddHHmmss').log"
    $sshArgs = @(
        '-p', $cfg.vps_port,
        '-i', $cfg.ssh_key_path,
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=10',
        '-o', 'BatchMode=yes',
        "$($cfg.vps_user)@$($cfg.vps_host)",
        'cat /root/projects/zoom-uploader-distributed/vps/uploaded.log'
    )
    $sshOut = & ssh.exe @sshArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        $sshOut | Out-File $tmpUploaded -Encoding utf8
        $vpsUploadedBasenames = @{}
        Get-Content $tmpUploaded -ErrorAction SilentlyContinue | ForEach-Object {
            $parts = $_ -split '\|'
            if ($parts.Count -ge 1 -and $parts[0]) {
                $bn = Split-Path -Leaf $parts[0]
                if ($bn) { $vpsUploadedBasenames[$bn] = $true }
            }
        }
        Log "VPS uploaded.log: $($vpsUploadedBasenames.Count) basenames у YT (server-side dedup активний)"
        Remove-Item $tmpUploaded -ErrorAction SilentlyContinue
    } else {
        Log "WARN: не вдалось зачитати VPS uploaded.log ($LASTEXITCODE) — server-side dedup ВИМКНЕНО на цей run, працюємо тільки на local state"
    }
} catch {
    Log "WARN: помилка SSH-fetch uploaded.log: $_ — server-side dedup ВИМКНЕНО"
}

# === Scan Zoom-folder ===
# Тільки відео: m4a — окремий audio-only трек Zoom, дублює звук вже у .mp4
$videoExt = @('.mp4', '.mkv', '.mov')
# -File flag відсутній у старих PowerShell (2.0/3.0). Використовуємо PSIsContainer для compat.
$candidates = Get-ChildItem -Path $cfg.zoom_folder -Recurse -ErrorAction SilentlyContinue |
              Where-Object { -not $_.PSIsContainer -and $videoExt -contains $_.Extension.ToLower() }

Log "Знайдено $($candidates.Count) відео-файлів у $($cfg.zoom_folder)"

$pushedCount = 0
$skippedCount = 0
$failedCount = 0

foreach ($file in $candidates) {
    $key = $file.FullName
    $size = $file.Length
    $mtime = $file.LastWriteTimeUtc.ToString('o')

    # === Skip якщо файл ще пишеться (Zoom часто пише ~30s після завершення meeting) ===
    if ($mtime -gt (Get-Date).AddMinutes(-2).ToUniversalTime().ToString('o')) {
        Log "  SKIP (writing): $($file.Name)"
        continue
    }

    # === Skip якщо вже pushed з тим самим size+mtime ===
    if ($state.ContainsKey($key)) {
        $prev = $state[$key]
        if ($prev.size -eq $size -and $prev.mtime -eq $mtime) {
            $skippedCount++
            continue
        }
    }

    # === Build remote filename з parent-folder як префікс ===
    # Zoom створює папки типу "2026-05-09 14.30.45 Назва зустрічі" — це наш title.
    # Sanitize spaces/special chars щоб не псувати scp/filesystem.
    $parentName = $file.Directory.Name
    # Замінити характери що ламають shell або погано читаються (spaces, brackets тощо) на дефіс.
    $safeParent = ($parentName -replace '[<>:"/\\|?*]', '_') -replace '\s+', '_'
    $remoteFileName = "${safeParent}__$($file.Name)"

    # === Server-side dedup: skip якщо вже у VPS uploaded.log ===
    if ($null -ne $vpsUploadedBasenames -and $vpsUploadedBasenames.ContainsKey($remoteFileName)) {
        Log "  SKIP (already on YouTube via VPS uploaded.log): $remoteFileName"
        # Заповнимо локальний state щоб наступний run скіпав швидко без SSH-check
        $state[$key] = @{
            size = $size
            mtime = $mtime
            pushed_at = (Get-Date -Format 'o')
            source = 'vps-dedup'
        }
        $skippedCount++
        continue
    }

    # === Push (через scp — вбудований у Win 10+) ===
    $remotePath = "$($cfg.vps_user)@$($cfg.vps_host):$($cfg.vps_inbox_path)/$remoteFileName"

    Log "  PUSH: $($file.Name) ($([math]::Round($size/1MB, 1)) MB) → $remoteFileName"
    $scpArgs = @(
        '-P', $cfg.vps_port,
        '-i', $cfg.ssh_key_path,
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=30',
        $file.FullName,
        $remotePath
    )
    $rsyncOut = & scp.exe @scpArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        $state[$key] = @{
            size = $size
            mtime = $mtime
            pushed_at = (Get-Date -Format 'o')
        }
        $pushedCount++
        Log "    OK"
        # === INCREMENTAL save: пишемо state після КОЖНОГО успішного push ===
        # Захист від Task Scheduler timeout-kill (1h limit у settings) — якщо скрипт
        # приб'ють у середині, попередні success вже у файлі і наступний run їх скіпне.
        try {
            $state | ConvertTo-Json -Depth 5 | Out-File $cfg.state_file -Encoding utf8 -ErrorAction Stop
        } catch {
            Log "    WARN: state save fail: $_"
        }
    } else {
        $failedCount++
        Log "    FAIL: $rsyncOut"
    }
}

# === Final state save (на випадок якщо incremental fail-or-був skipped-only run) ===
$state | ConvertTo-Json -Depth 5 | Out-File $cfg.state_file -Encoding utf8

Log "Підсумок: pushed=$pushedCount, skipped=$skippedCount, failed=$failedCount"
Log "═══ push-agent end ═══"
