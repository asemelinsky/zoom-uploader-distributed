# install-zoom-uploader.ps1
# Self-installer для Windows-комп'ютера, що пушить Zoom-records у VPS.
#
# Запуск:
#   PowerShell → правий клік → Run as Administrator (для Task Scheduler).
#   .\install-zoom-uploader.ps1
#
# Що робить:
#   1. Питає у user: Zoom-folder path, comp_name (унікальна назва компа)
#   2. Створює C:\zoom-uploader\ структуру
#   3. Generates ed25519 SSH key
#   4. Виводить public key — user копіює його у VPS authorized_keys (інструкція друкується)
#   5. Чекає підтвердження що key додано на VPS
#   6. Тестовий push (echo file)
#   7. Створює Task Scheduler — hourly trigger
#   8. Готово.

#Requires -Version 5.0

$ErrorActionPreference = 'Stop'

# === Захист: запуск як Administrator ===
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[X] Цей скрипт треба запускати як Administrator (для Task Scheduler)." -ForegroundColor Red
    Write-Host "    PowerShell → правий клік → Run as Administrator." -ForegroundColor Yellow
    exit 1
}

Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Zoom Uploader — installer"                                       -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# === 1. Опитування user-а ===
$defaultZoom = "D:\Zoom"
$zoomPath = Read-Host "Шлях до Zoom-folder [$defaultZoom]"
if ([string]::IsNullOrWhiteSpace($zoomPath)) { $zoomPath = $defaultZoom }
if (-not (Test-Path $zoomPath)) {
    Write-Host "[X] Папка не існує: $zoomPath" -ForegroundColor Red
    exit 1
}

$defaultName = ($env:COMPUTERNAME).ToLower()
$compName = Read-Host "Унікальна назва цього компа (sub-folder в VPS-inbox) [$defaultName]"
if ([string]::IsNullOrWhiteSpace($compName)) { $compName = $defaultName }
$compName = $compName -replace '[^a-zA-Z0-9_-]', '-'

Write-Host ""
Write-Host "  Zoom folder:  $zoomPath"
Write-Host "  Comp name:    $compName (sub-folder /root/zoom-inbox/$compName/)"
Write-Host ""
$confirm = Read-Host "Підтвердити? [Y/n]"
if ($confirm -match '^[Nn]') { Write-Host "Скасовано."; exit 0 }

# === 2. Структура C:\zoom-uploader\ ===
$installDir = "C:\zoom-uploader"
$sshDir = "$installDir\.ssh"
$logDir = "$installDir\logs"
New-Item -ItemType Directory -Force -Path $installDir, $sshDir, $logDir | Out-Null
Write-Host "[OK] Створено $installDir" -ForegroundColor Green

# === 3. SSH key (ed25519) ===
$sshKeyPath = "$sshDir\id_ed25519"
$sshPubPath = "$sshKeyPath.pub"

if (-not (Test-Path $sshKeyPath)) {
    Write-Host ""
    Write-Host "[..] Генерую SSH key (ed25519, без passphrase для cron-friendly)..."
    & ssh-keygen.exe -t ed25519 -f $sshKeyPath -N '""' -C "zoom-uploader-$compName" 2>&1 | Out-Null
    if (-not (Test-Path $sshKeyPath)) {
        Write-Host "[X] ssh-keygen failed. Перевір що OpenSSH встановлений (Windows 10+ build 1803+)." -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] Згенеровано $sshKeyPath" -ForegroundColor Green
} else {
    Write-Host "[!] SSH key вже існує: $sshKeyPath (використовую existing)" -ForegroundColor Yellow
}

$pubKey = (Get-Content $sshPubPath -Raw).Trim()

# === 4. Інструкція для user — додати public key на VPS ===
$vpsHost = "46.225.227.42"
$vpsPort = 2222
$inboxPath = "/root/zoom-inbox/$compName"
$pubParts = $pubKey -split ' ', 3
# Без command= restriction — scp не сумісний з fixed-command. Обмежуємось no-port/agent/X11-forwarding.
$restrictedKey = 'no-port-forwarding,no-agent-forwarding,no-X11-forwarding ' + $pubParts[0] + ' ' + $pubParts[1] + " zoom-uploader-$compName"

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  ДІЯ ПОТРІБНА: додай public key на VPS"                            -ForegroundColor Yellow
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Зайди на VPS:"
Write-Host "   ssh -p $vpsPort root@$vpsHost"
Write-Host ""
Write-Host "2. Створи inbox-папку:"
Write-Host "   mkdir -p $inboxPath"
Write-Host ""
Write-Host "3. Додай у /root/.ssh/authorized_keys рядок:"
Write-Host ""
Write-Host "  $restrictedKey" -ForegroundColor Cyan
Write-Host ""
Write-Host "4. Перевір permissions:"
Write-Host "   chmod 600 /root/.ssh/authorized_keys"
Write-Host ""
$ready = Read-Host "Натисни Enter коли key додано на VPS (або 'q' щоб скасувати)"
if ($ready -match '^[Qq]') { Write-Host "Скасовано."; exit 0 }

# === 5. Тест SSH push ===
Write-Host ""
Write-Host "[..] Тестую SSH connection (через scp)..."
$testFile = "$installDir\test-push.txt"
"test from $compName at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $testFile -Encoding utf8
$testResult = & scp.exe -P $vpsPort -i $sshKeyPath -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $testFile "root@${vpsHost}:$inboxPath/" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] SCP push працює." -ForegroundColor Green
    Remove-Item $testFile -Force
} else {
    Write-Host "[X] SCP push failed:" -ForegroundColor Red
    Write-Host $testResult
    Write-Host ""
    Write-Host "Перевір що:"
    Write-Host "  - public key додано на VPS у authorized_keys (без command= restriction)"
    Write-Host "  - inbox-папка існує: ssh -p $vpsPort root@$vpsHost 'ls $inboxPath'"
    Write-Host "  - scp.exe вбудований у Windows 10+ build 1803+. Якщо нема — Settings → Apps → Optional features → OpenSSH Client"
    exit 1
}

# === 6. config.json ===
$config = @{
    comp_name = $compName
    zoom_folder = $zoomPath
    vps_host = $vpsHost
    vps_port = $vpsPort
    vps_user = "root"
    vps_inbox_path = $inboxPath
    ssh_key_path = $sshKeyPath
    log_dir = $logDir
    state_file = "$installDir\pushed.json"
} | ConvertTo-Json -Depth 4

$config | Out-File "$installDir\config.json" -Encoding utf8
Write-Host "[OK] Створено $installDir\config.json" -ForegroundColor Green

# === 7. Деплой push-agent.ps1 ===
$agentSrc = Join-Path $PSScriptRoot "push-agent.ps1"
if (-not (Test-Path $agentSrc)) {
    Write-Host "[X] push-agent.ps1 не знайдено поряд з installer-ом ($agentSrc)" -ForegroundColor Red
    exit 1
}
Copy-Item $agentSrc "$installDir\push-agent.ps1" -Force
Write-Host "[OK] Скопійовано push-agent.ps1" -ForegroundColor Green

# === 8. Task Scheduler — hourly ===
$taskName = "ZoomUploaderPush"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installDir\push-agent.ps1`""
$trigger = New-ScheduledTaskTrigger -Daily -At "00:15"
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At "00:15" -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration ([TimeSpan]::FromHours(24))).Repetition
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType S4U -RunLevel Highest

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description "Push Zoom-records у VPS-inbox раз на годину" | Out-Null
Write-Host "[OK] Task Scheduler entry: $taskName (hourly о 15-й хвилині)" -ForegroundColor Green

# === 9. Final ===
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Готово!"                                                         -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  • Push раз на годину (Task Scheduler '$taskName')"
Write-Host "  • Logs: $logDir\"
Write-Host "  • State: $installDir\pushed.json"
Write-Host ""
Write-Host "Manual run для перевірки:"
Write-Host "  powershell -File `"$installDir\push-agent.ps1`""
Write-Host ""
Write-Host "Видалити (якщо треба):"
Write-Host "  Unregister-ScheduledTask -TaskName $taskName -Confirm:`$false"
Write-Host "  Remove-Item -Recurse -Force '$installDir'"
Write-Host ""
