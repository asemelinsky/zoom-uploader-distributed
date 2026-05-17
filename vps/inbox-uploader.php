<?php
// inbox-uploader.php
//
// VPS-side processor: scan /root/zoom-inbox/<comp>/, upload на YouTube,
// ffmpeg thumbnail → /var/www/bajka.pp.ua/screenshots/, TG notification.
//
// Trigger: cron — кожні 15 хвилин (див. operations.md).
//
// НЕ видаляє файли з inbox — це робить inbox-cleaner.sh за TTL 2 дні.
//
// Адаптовано з /root/projects/php/youtube-uploader/zoom_upload.php (Windows version).

require_once '/root/projects/php/youtube-uploader/vendor/autoload.php';

// === Налаштування ===
$inboxRoot       = '/root/zoom-inbox';
$screenshotsDir  = '/var/www/bajka.pp.ua/screenshots';
$thumbWebPrefix  = 'https://bajka.pp.ua/screenshots/';
$logFile         = '/var/log/zoom-uploader.log';
$uploadedLog     = '/root/projects/zoom-uploader-distributed/vps/uploaded.log';
$credentialsPath = '/root/projects/php/youtube-uploader/credentials.json';
$tokenPath       = '/root/projects/php/youtube-uploader/token.json';

// Telegram credentials — load from vps/.env (gitignored). Див. vps/.env.example.
$envPath = __DIR__ . '/.env';
if (!file_exists($envPath)) {
    fwrite(STDERR, "FATAL: $envPath not found. Copy vps/.env.example → vps/.env and fill in values.\n");
    exit(1);
}
$env = parse_ini_file($envPath);
$telegramToken   = $env['TELEGRAM_BOT_TOKEN'] ?? '';
$telegramChatId  = $env['TELEGRAM_CHAT_ID']   ?? '';
if ($telegramToken === '' || $telegramChatId === '') {
    fwrite(STDERR, "FATAL: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID missing in $envPath.\n");
    exit(1);
}

// Тільки відео — m4a окремий audio-only трек Zoom (звук вже у mp4).
$videoExt = ['mp4', 'mkv', 'mov'];

// === Helpers ===
function logMsg(string $msg): void {
    global $logFile;
    $line = '[' . date('Y-m-d H:i:s') . '] ' . $msg;
    echo $line . "\n";
    file_put_contents($logFile, $line . "\n", FILE_APPEND | LOCK_EX);
}

function tg_send(string $text): void {
    global $telegramToken, $telegramChatId;
    $url = "https://api.telegram.org/bot{$telegramToken}/sendMessage";
    $data = http_build_query([
        'chat_id' => $telegramChatId,
        'text' => $text,
        'disable_web_page_preview' => false,
    ]);
    $ctx = stream_context_create([
        'http' => ['method' => 'POST', 'header' => 'Content-Type: application/x-www-form-urlencoded', 'content' => $data, 'timeout' => 15],
    ]);
    @file_get_contents($url, false, $ctx);
}

function load_uploaded(): array {
    global $uploadedLog;
    return file_exists($uploadedLog)
        ? array_filter(file($uploadedLog, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES))
        : [];
}

function mark_uploaded(string $absPath, string $videoId): void {
    global $uploadedLog;
    file_put_contents($uploadedLog, "{$absPath}|{$videoId}|" . date('c') . "\n", FILE_APPEND | LOCK_EX);
}

function already_uploaded(string $absPath, array $log): bool {
    foreach ($log as $line) {
        if (str_starts_with($line, $absPath . '|')) return true;
    }
    return false;
}

function generate_thumbnail(string $videoPath, string $thumbName): ?string {
    global $screenshotsDir;
    if (!is_dir($screenshotsDir)) {
        if (!@mkdir($screenshotsDir, 0755, true)) return null;
    }
    $thumbPath = $screenshotsDir . '/' . $thumbName;

    // Беремо кадр з 15% тривалості відео. Fallback на 5с якщо ffprobe не зміг.
    $probeCmd = sprintf(
        'ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 %s 2>/dev/null',
        escapeshellarg($videoPath)
    );
    $duration = (float) trim((string) shell_exec($probeCmd));
    $seekSec = $duration > 0 ? max(1, (int) round($duration * 0.15)) : 5;

    $cmd = sprintf(
        'ffmpeg -y -ss %d -i %s -frames:v 1 -q:v 4 -vf scale=1280:-2 %s 2>&1',
        $seekSec,
        escapeshellarg($videoPath),
        escapeshellarg($thumbPath)
    );
    exec($cmd, $out, $exit);
    return ($exit === 0 && file_exists($thumbPath)) ? $thumbPath : null;
}

// === Lock — не дозволяємо паралельний запуск ===
$lockFile = '/var/lock/zoom-inbox-uploader.lock';
$lockFp = fopen($lockFile, 'c');
if (!flock($lockFp, LOCK_EX | LOCK_NB)) {
    // Інший instance уже працює — мовчки exit (нормально, cron спрацював коли ще обробляється)
    exit(0);
}

logMsg("═══ inbox-uploader start ═══");

// === Google Client + Token refresh ===
try {
    $client = new Google_Client();
    $client->setAuthConfig($credentialsPath);
    $client->addScope(Google_Service_YouTube::YOUTUBE_UPLOAD);
    $client->setAccessType('offline');

    if (!file_exists($tokenPath)) {
        logMsg("FATAL: token.json не знайдено. Auth з compa спершу.");
        exit(1);
    }
    $client->setAccessToken(json_decode(file_get_contents($tokenPath), true));

    if ($client->isAccessTokenExpired()) {
        $refreshToken = $client->getRefreshToken();
        if (!$refreshToken) {
            logMsg("FATAL: refresh_token відсутній — потрібна re-auth з comp interactively.");
            tg_send("⚠️ Zoom Uploader: Google token expired без refresh. Потрібна re-auth.");
            exit(1);
        }
        logMsg("Оновлюю access token...");
        $client->fetchAccessTokenWithRefreshToken($refreshToken);
        file_put_contents($tokenPath, json_encode($client->getAccessToken()));
    }
    $youtube = new Google_Service_YouTube($client);
} catch (Throwable $e) {
    logMsg("FATAL Google client init: " . $e->getMessage());
    tg_send("⚠️ Zoom Uploader Google client failed: " . $e->getMessage());
    exit(1);
}

// === Process inbox ===
$uploaded = load_uploaded();
$compDirs = glob("{$inboxRoot}/*", GLOB_ONLYDIR);
logMsg("Знайдено " . count($compDirs) . " comp-папок у $inboxRoot");

$totalUploaded = 0;
$totalFailed = 0;

foreach ($compDirs as $compDir) {
    $compName = basename($compDir);
    $files = [];
    foreach ($videoExt as $ext) {
        $files = array_merge($files, glob("{$compDir}/*.{$ext}"));
        $files = array_merge($files, glob("{$compDir}/*/*.{$ext}"));  // Zoom часто кладе у subfolders
    }
    logMsg("[{$compName}] видео-файлів: " . count($files));

    foreach ($files as $videoPath) {
        if (already_uploaded($videoPath, $uploaded)) continue;

        // Skip якщо файл ще пишеться (mtime <2 хв тому)
        if (filemtime($videoPath) > (time() - 120)) {
            logMsg("[{$compName}] SKIP (recent mtime): " . basename($videoPath));
            continue;
        }

        // Title з parent-folder name. Push-agent prepend-ить "<folder>__<file>" перед scp.
        // Якщо filename містить "__" — беремо частину до нього як event-name.
        // Інакше fallback на raw filename (legacy files без префіксу).
        $rawName = basename($videoPath, '.' . pathinfo($videoPath, PATHINFO_EXTENSION));
        if (strpos($rawName, '__') !== false) {
            list($eventName, $_filePart) = explode('__', $rawName, 2);
            // Розкодувати назад читабельне: підкреслення → пробіли (push-agent заміняв spaces на _)
            $eventName = str_replace('_', ' ', $eventName);
        } else {
            $eventName = $rawName;
        }
        $title = sprintf('[%s] %s', $compName, $eventName);
        logMsg("[{$compName}] UPLOAD: " . basename($videoPath) . " → title: " . $title);

        try {
            // YouTube upload (resumable, chunks 1MB)
            $snippet = new Google_Service_YouTube_VideoSnippet();
            $snippet->setTitle($title);
            $snippet->setDescription("Auto-upload from {$compName} via zoom-uploader-distributed");

            $status = new Google_Service_YouTube_VideoStatus();
            $status->setPrivacyStatus('unlisted');

            $video = new Google_Service_YouTube_Video();
            $video->setSnippet($snippet);
            $video->setStatus($status);

            $client->setDefer(true);
            $insertReq = $youtube->videos->insert('snippet,status', $video);

            $chunkSize = 1 * 1024 * 1024;
            $media = new Google_Http_MediaFileUpload($client, $insertReq, 'video/*', null, true, $chunkSize);
            $media->setFileSize(filesize($videoPath));

            $handle = fopen($videoPath, 'rb');
            $uploadStatus = false;
            while (!$uploadStatus && !feof($handle)) {
                $chunk = fread($handle, $chunkSize);
                $uploadStatus = $media->nextChunk($chunk);
            }
            fclose($handle);
            $client->setDefer(false);

            $videoId = $uploadStatus['id'] ?? null;
            if (!$videoId) {
                throw new RuntimeException("YouTube не повернув videoId");
            }
            $videoUrl = "https://youtube.com/watch?v={$videoId}";
            logMsg("[{$compName}]   YouTube ID: {$videoId}");

            // Thumbnail
            $thumbName = $compName . '_' . pathinfo($videoPath, PATHINFO_FILENAME) . '_' . substr(md5($videoPath), 0, 6) . '.jpg';
            $thumbPath = generate_thumbnail($videoPath, $thumbName);
            $thumbUrl = $thumbPath ? $thumbWebPrefix . rawurlencode($thumbName) : null;

            // TG ping (без approve кнопок — як просив user)
            $msg = "🎬 {$title}\n";
            $msg .= "📺 {$videoUrl}\n";
            if ($thumbUrl) $msg .= "🖼 {$thumbUrl}\n";
            $msg .= "📁 {$videoPath}";
            tg_send($msg);

            mark_uploaded($videoPath, $videoId);
            $totalUploaded++;
        } catch (Throwable $e) {
            $err = $e->getMessage();
            logMsg("[{$compName}]   FAIL: {$err}");
            tg_send("❌ Upload failed для " . basename($videoPath) . " ({$compName}): {$err}");
            $totalFailed++;
            // Якщо quota exhausted — зупиняємо весь loop
            if (str_contains($err, 'quotaExceeded')) {
                logMsg("Quota exhausted — зупиняю на сьогодні");
                break 2;
            }
        }
    }
}

logMsg("Підсумок: uploaded={$totalUploaded}, failed={$totalFailed}");
logMsg("═══ inbox-uploader end ═══");

flock($lockFp, LOCK_UN);
fclose($lockFp);
