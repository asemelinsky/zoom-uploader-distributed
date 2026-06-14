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
        # PS 5.1 (Win 10/11 stock) не має `-AsHashtable`. Парсимо як PSCustomObject
        # і ручно конвертуємо у hashtable (значення лишаємо PSCustomObject — їх
        # читаємо через dot-notation $state[$key].size що працює для обох типів).
        $jsonRaw = Get-Content $cfg.state_file -Raw -Encoding UTF8
        if ($jsonRaw -and $jsonRaw.Trim()) {
            $parsed = $jsonRaw | ConvertFrom-Json
            if ($parsed) {
                $parsed.PSObject.Properties | ForEach-Object {
                    $state[$_.Name] = $_.Value
                }
            }
        }
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
    # ВАЖЛИВО — використовуємо SCP (binary copy) а не SSH cat (stdout decoded by PS
    # console code page, що CP-866 на UA Win → кирилиця в basename ламається,
    # HashSet lookup не співпадає, файли push-ляться повторно).
    # SCP копіює байт-у-байт; читаємо локально з явним -Encoding UTF8.
    $tmpUploaded = Join-Path $env:TEMP "vps-uploaded-$(Get-Date -Format 'yyyyMMddHHmmss').log"
    $scpArgs = @(
        '-P', $cfg.vps_port,
        '-i', $cfg.ssh_key_path,
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=10',
        '-o', 'BatchMode=yes',
        "$($cfg.vps_user)@$($cfg.vps_host):/root/projects/zoom-uploader-distributed/vps/uploaded.log",
        $tmpUploaded
    )
    $scpOut = & scp.exe @scpArgs 2>&1
    if ($LASTEXITCODE -eq 0 -and (Test-Path $tmpUploaded)) {
        # case-insensitive HashSet (Win filesystem is case-insensitive)
        $vpsUploadedBasenames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        Get-Content $tmpUploaded -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            $line = $_
            if ($line) {
                $parts = $line -split '\|'
                if ($parts.Count -ge 1 -and $parts[0]) {
                    $bn = Split-Path -Leaf $parts[0]
                    if ($bn) { [void]$vpsUploadedBasenames.Add($bn) }
                }
            }
        }
        Log "VPS uploaded.log: $($vpsUploadedBasenames.Count) basenames у YT (server-side dedup активний)"
        Remove-Item $tmpUploaded -ErrorAction SilentlyContinue
    } else {
        Log "WARN: не вдалось scp VPS uploaded.log ($LASTEXITCODE): $scpOut — server-side dedup ВИМКНЕНО на цей run, працюємо тільки на local state"
    }
} catch {
    Log "WARN: помилка SCP-fetch uploaded.log: $_ — server-side dedup ВИМКНЕНО"
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
    # HashSet.Contains (а не .ContainsKey — це HashSet, не Dictionary)
    if ($null -ne $vpsUploadedBasenames -and $vpsUploadedBasenames.Contains($remoteFileName)) {
        Log "  SKIP (already on YouTube via VPS uploaded.log): $remoteFileName"
        # Заповнимо локальний state щоб наступний run скіпав швидко без SCP-check
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

# === Auto-cleanup: видалити локальні Zoom-папки повністю pushed > N днів тому ===
# Default TTL = 7d. Можна змінити у config.json -> "cleanup_age_days": N. Якщо 0 — вимкнено.
$cleanupAgeDays = 7
if ($cfg.PSObject.Properties.Match('cleanup_age_days').Count -gt 0) {
    $cleanupAgeDays = [int]$cfg.cleanup_age_days
}

if ($cleanupAgeDays -gt 0) {
    Log "Auto-cleanup перевірка (TTL=${cleanupAgeDays}d)..."
    $now = Get-Date
    $deletedFolders = 0
    $deletedBytes = 0L

    # Групуємо state по parent-folder
    $folderGroups = @{}
    foreach ($entry in $state.GetEnumerator()) {
        $parentDir = Split-Path -Parent $entry.Key
        if (-not $folderGroups.ContainsKey($parentDir)) {
            $folderGroups[$parentDir] = New-Object 'System.Collections.Generic.List[string]'
        }
        $folderGroups[$parentDir].Add($entry.Key)
    }

    foreach ($folder in @($folderGroups.Keys)) {
        if (-not (Test-Path $folder)) { continue }
        # SAFETY: тільки у межах Zoom folder, ніколи назовні
        $zoomRoot = (Resolve-Path $cfg.zoom_folder -ErrorAction SilentlyContinue).Path
        $folderResolved = (Resolve-Path $folder -ErrorAction SilentlyContinue).Path
        if (-not $zoomRoot -or -not $folderResolved -or -not $folderResolved.StartsWith($zoomRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        # Не видаляти сам корінь Zoom folder
        if ($folderResolved.TrimEnd('\') -eq $zoomRoot.TrimEnd('\')) { continue }

        # Перевіряємо що ВСІ поточні video-файли у папці є у state і pushed >= TTL days ago
        $currentVideos = Get-ChildItem -Path $folder -Recurse -ErrorAction SilentlyContinue |
                         Where-Object { -not $_.PSIsContainer -and $videoExt -contains $_.Extension.ToLower() }

        if ($currentVideos.Count -eq 0) { continue }

        $allOldEnough = $true
        $oldestAge = 0
        foreach ($video in $currentVideos) {
            if (-not $state.ContainsKey($video.FullName)) {
                $allOldEnough = $false
                break
            }
            try {
                $pushedAt = [DateTime]::Parse($state[$video.FullName].pushed_at)
                $ageDays = ($now - $pushedAt).TotalDays
                if ($ageDays -lt $cleanupAgeDays) { $allOldEnough = $false; break }
                if ($ageDays -gt $oldestAge) { $oldestAge = $ageDays }
            } catch {
                $allOldEnough = $false; break
            }
        }

        if ($allOldEnough) {
            $folderSize = (Get-ChildItem $folder -Recurse -ErrorAction SilentlyContinue |
                           Measure-Object -Property Length -Sum).Sum
            try {
                Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
                Log "  CLEANUP: $folder ($([math]::Round($folderSize/1MB, 0)) MB, oldest push $([math]::Round($oldestAge,1))d ago)"
                $deletedFolders++
                $deletedBytes += $folderSize
                # Прибираємо stale state-entries
                foreach ($video in $currentVideos) {
                    $state.Remove($video.FullName)
                }
            } catch {
                Log "  CLEANUP FAIL: $folder — $_"
            }
        }
    }

    if ($deletedFolders -gt 0) {
        Log "Auto-cleanup підсумок: видалено $deletedFolders папок ($([math]::Round($deletedBytes/1GB,2)) GB)"
    }
}

# === Final state save (на випадок якщо incremental fail-or-був skipped-only run) ===
$state | ConvertTo-Json -Depth 5 | Out-File $cfg.state_file -Encoding utf8

Log "Підсумок: pushed=$pushedCount, skipped=$skippedCount, failed=$failedCount"
Log "═══ push-agent end ═══"
