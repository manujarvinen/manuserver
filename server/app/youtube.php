<?php
// youtube.php — turning whatever someone pasted into a video id and a title.

declare(strict_types=1);

/** Hosts a YouTube link can legitimately arrive on. */
const YOUTUBE_HOSTS = [
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
    'youtu.be',
    'www.youtu.be',
];

/** Path prefixes that are followed by the id itself. */
const YOUTUBE_ID_PATHS = ['shorts', 'embed', 'live', 'v', 'e'];

/** Seconds to wait for YouTube to tell us a title before giving up on it. */
const OEMBED_TIMEOUT = 4;

/**
 * Pull the 11-character video id out of a pasted string, or null if there
 * isn't one.
 *
 * Everything is checked against the host allowlist first. Without that, a
 * regex hunting for eleven id-ish characters happily finds them in any URL at
 * all, and the site ends up embedding links to somewhere else entirely.
 */
function youtube_video_id(string $input): ?string
{
    $input = trim($input);

    if ($input === '') {
        return null;
    }

    // A bare id, pasted on its own.
    if (preg_match('~^[A-Za-z0-9_-]{11}$~', $input)) {
        return $input;
    }

    // parse_url wants a scheme to find the host; people paste without one.
    if (!preg_match('~^https?://~i', $input)) {
        $input = 'https://' . $input;
    }

    $parts = parse_url($input);

    if ($parts === false || !isset($parts['host'])) {
        return null;
    }

    if (!in_array(strtolower($parts['host']), YOUTUBE_HOSTS, true)) {
        return null;
    }

    // youtube.com/watch?v=ID
    if (isset($parts['query'])) {
        parse_str($parts['query'], $params);

        if (isset($params['v']) && is_string($params['v']) && is_video_id($params['v'])) {
            return $params['v'];
        }
    }

    $segments = array_values(array_filter(explode('/', $parts['path'] ?? '')));

    if ($segments === []) {
        return null;
    }

    // youtu.be/ID — the id is the whole path.
    if (str_ends_with(strtolower($parts['host']), 'youtu.be') && is_video_id($segments[0])) {
        return $segments[0];
    }

    // youtube.com/shorts/ID and its relatives.
    if (count($segments) >= 2
        && in_array(strtolower($segments[0]), YOUTUBE_ID_PATHS, true)
        && is_video_id($segments[1])
    ) {
        return $segments[1];
    }

    return null;
}

function is_video_id(string $candidate): bool
{
    return (bool) preg_match('~^[A-Za-z0-9_-]{11}$~', $candidate);
}

function youtube_watch_url(string $videoId): string
{
    return 'https://www.youtube.com/watch?v=' . $videoId;
}

/**
 * Ask YouTube what a video is called, or null if it won't say.
 *
 * oEmbed is the only endpoint here that needs no API key and no quota. It
 * also answers "does this video exist and is it public?" — a private, deleted
 * or nonexistent id returns an error status rather than a title, which is why
 * a null from this function is worth showing the poster rather than swallowing.
 */
function youtube_title(string $videoId): ?string
{
    $url = 'https://www.youtube.com/oembed?format=json&url='
        . rawurlencode(youtube_watch_url($videoId));

    $body = fetch_url($url);

    if ($body === null) {
        return null;
    }

    $data = json_decode($body, true);

    if (!is_array($data) || !isset($data['title']) || !is_string($data['title'])) {
        return null;
    }

    return trim_title($data['title']);
}

/**
 * Titles go into a single feed line. 120 characters is where one stops being
 * a title and starts being the description, and the database agrees.
 */
function trim_title(string $title): string
{
    $title = trim(preg_replace('/\s+/u', ' ', $title) ?? '');

    if (mb_strlen($title) <= 120) {
        return $title;
    }

    $cut = mb_substr($title, 0, 120);
    $lastSpace = mb_strrpos($cut, ' ');

    // Prefer a word boundary, but not one so early that the title loses its
    // sense; below 80 characters, a hard cut reads better.
    return rtrim($lastSpace !== false && $lastSpace > 80 ? mb_substr($cut, 0, $lastSpace) : $cut) . '…';
}

/**
 * A GET that returns the body or null. curl if the extension is there,
 * otherwise the stream wrapper — the server has curl, the odd development
 * machine might not.
 */
function fetch_url(string $url): ?string
{
    if (function_exists('curl_init')) {
        $handle = curl_init($url);
        curl_setopt_array($handle, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_TIMEOUT        => OEMBED_TIMEOUT,
            CURLOPT_CONNECTTIMEOUT => OEMBED_TIMEOUT,
            CURLOPT_USERAGENT      => 'tastehopping',
        ]);

        $body = curl_exec($handle);
        $status = curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
        curl_close($handle);

        return ($body === false || $status !== 200) ? null : (string) $body;
    }

    $context = stream_context_create(['http' => [
        'timeout'       => OEMBED_TIMEOUT,
        'ignore_errors' => true,
        'user_agent'    => 'tastehopping',
    ]]);

    $body = @file_get_contents($url, false, $context);

    if ($body === false) {
        return null;
    }

    // $http_response_header is set by the wrapper in the local scope.
    $status = isset($http_response_header[0]) && preg_match('~ (\d{3}) ~', $http_response_header[0], $m)
        ? (int) $m[1]
        : 0;

    return $status === 200 ? $body : null;
}
