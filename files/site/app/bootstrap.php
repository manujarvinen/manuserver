<?php
// bootstrap.php — everything every request needs: configuration, the database
// handle, the session, and the handful of helpers the views lean on.
//
// This file lives outside public_html on purpose. nginx serves public_html and
// nothing else, so no amount of URL guessing reaches the application code or
// the database credentials it reads.

declare(strict_types=1);

const APP_DIR  = __DIR__;

// Where provision.sh leaves the generated database password. Mode 640,
// root:http, so php-fpm can read it and a shell user cannot. Absent during
// local development, where run-local.sh exports the variables instead.
const ENV_FILE = '/etc/manuserver/db.env';

// How many distinct accounts have to report a post before it stops appearing
// in feeds. Nobody reviews these by hand; the number is the whole policy.
const REPORT_THRESHOLD = 3;

// Rows per feed page.
const PAGE_SIZE = 8;

// How many ranked accounts there have to be before a reputation is shown.
//
// Reputation is a percentile, so the endpoints are always occupied: whoever
// leads is at 1000 whether they lead by one like or ten thousand. With two
// accounts, a single like puts someone at the top of the scale, which reads as
// a broken number rather than a true one.
//
// Below this many, profiles say "new" instead. The percentile is still
// computed and the slider still filters on it — a position among four people is
// a fine thing to sort by and a silly thing to print.
const REPUTATION_MIN_POPULATION = 10;

/**
 * Load KEY=value lines into the environment, without overriding anything the
 * process was already given. Deliberately not a full dotenv parser — it reads
 * exactly the file provision.sh writes.
 */
function load_env_file(string $path): void
{
    if (!is_readable($path)) {
        return;
    }

    foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $line = trim($line);
        if ($line === '' || str_starts_with($line, '#') || !str_contains($line, '=')) {
            continue;
        }

        [$key, $value] = explode('=', $line, 2);
        $key = trim($key);

        if ($key !== '' && getenv($key) === false) {
            putenv($key . '=' . trim($value, " \t\"'"));
        }
    }
}

/**
 * The one database handle for this request.
 */
function db(): PDO
{
    static $pdo = null;

    if ($pdo instanceof PDO) {
        return $pdo;
    }

    $dsn = sprintf(
        'pgsql:host=%s;port=%s;dbname=%s',
        getenv('DB_HOST') ?: '/run/postgresql',
        getenv('DB_PORT') ?: '5432',
        getenv('DB_NAME') ?: 'tastehopping'
    );

    $pdo = new PDO($dsn, getenv('DB_USER') ?: 'tastehopping', getenv('DB_PASSWORD') ?: '', [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        // Real prepared statements, so a placeholder can never be talked into
        // being anything but a value.
        PDO::ATTR_EMULATE_PREPARES   => false,
    ]);

    return $pdo;
}

/**
 * Run a query with bound parameters and hand back every row.
 *
 * @param array<string,mixed> $params
 * @return list<array<string,mixed>>
 */
function query(string $sql, array $params = []): array
{
    $statement = db()->prepare($sql);
    $statement->execute($params);

    return $statement->fetchAll();
}

/**
 * As query(), for the cases that return one row or none.
 *
 * @param array<string,mixed> $params
 * @return array<string,mixed>|null
 */
function query_one(string $sql, array $params = []): ?array
{
    $rows = query($sql, $params);

    return $rows[0] ?? null;
}

/**
 * As query(), for statements whose rows are not wanted.
 *
 * @param array<string,mixed> $params
 */
function execute(string $sql, array $params = []): int
{
    $statement = db()->prepare($sql);
    $statement->execute($params);

    return $statement->rowCount();
}

function start_session(): void
{
    // The seed script pulls in this file for its database helpers. There is
    // no browser at the other end of a CLI run and no cookie to set.
    if (PHP_SAPI === 'cli' || session_status() === PHP_SESSION_ACTIVE) {
        return;
    }

    session_name('tastehopping');
    session_set_cookie_params([
        'lifetime' => 60 * 60 * 24 * 365,
        'path'     => '/',
        'httponly' => true,
        // Lax rather than Strict: arriving from a link someone shared should
        // still find you logged in.
        'samesite' => 'Lax',
        'secure'   => is_https(),
    ]);
    session_start();
}

function is_https(): bool
{
    return ($_SERVER['HTTPS'] ?? '') === 'on'
        || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
}

/**
 * A URL for something in the document root, stamped with when it last changed.
 *
 * Cloudflare caches .css and .js for four hours by default, so a deploy would
 * otherwise leave every visitor — including you — on the previous stylesheet
 * until it expired or somebody remembered to purge the cache by hand. The
 * modification time in the query string makes an edited file a different URL,
 * which nothing has cached yet.
 *
 * Falls back to no stamp rather than failing if the file is missing: a
 * stylesheet that 404s is a broken page, and a stylesheet with no version is
 * only a stale one.
 */
function asset(string $path): string
{
    $stamp = @filemtime(dirname(APP_DIR) . '/public_html' . $path);

    return $stamp === false ? $path : $path . '?v=' . $stamp;
}

/** Escape for HTML. Named short because every view uses it constantly. */
function h(?string $text): string
{
    return htmlspecialchars($text ?? '', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function redirect(string $path): never
{
    // 303 so a redirect after POST is always re-fetched with GET.
    header('Location: ' . $path, true, 303);
    exit;
}

/** One message carried across a redirect and shown once. */
function flash(string $message): void
{
    $_SESSION['flash'] = $message;
}

function take_flash(): ?string
{
    $message = $_SESSION['flash'] ?? null;
    unset($_SESSION['flash']);

    return $message;
}

function csrf_token(): string
{
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(16));
    }

    return $_SESSION['csrf'];
}

/** A hidden input carrying the CSRF token. Every form in the site has one. */
function csrf_field(): string
{
    return '<input type="hidden" name="_csrf" value="' . h(csrf_token()) . '">';
}

/**
 * Reject a POST whose token is missing or wrong. hash_equals rather than ===
 * so the comparison does not leak the token through its timing.
 */
function require_csrf(): void
{
    $sent = $_POST['_csrf'] ?? '';

    if (!is_string($sent) || !hash_equals(csrf_token(), $sent)) {
        http_response_code(400);
        exit('bad request');
    }
}

// --- telling a person from a script ------------------------------------------
//
// Two checks, both free and both invisible to anyone actually reading the page.
// Neither is strong on its own. Together they cost a script the two things it
// is trying to avoid spending: time, and attention to the page it is posting to.
//
// Deliberately not a CAPTCHA. This site loads nothing from anyone else, and a
// challenge widget would be a third party watching every visitor arrive — on a
// site whose whole claim is that nobody is watching.

/** Below this many seconds between opening a form and sending it, it wasn't read. */
const MIN_FORM_SECONDS = 2;

/** Above this, the page has been sitting open long enough to be stale. */
const MAX_FORM_SECONDS = 3600;

/** Remember when a form went on screen. */
function mark_form_opened(string $form): void
{
    $_SESSION['form_opened'][$form] = time();
}

/**
 * Was this submission plausibly typed by a person?
 *
 * The timestamp lives in the session rather than in the form, so there is
 * nothing for a script to read off the page and replay. It is consumed on use:
 * one rendered form buys one submission, which is what stops a single fetch of
 * the page being turned into a thousand posts.
 *
 * The honeypot is a text input hidden with CSS. A person never sees it and a
 * browser never fills it. It is named `email` because form-fillers reach for
 * that one first, and because this site has no use for the real thing.
 */
function submission_looks_human(string $form): bool
{
    $opened = $_SESSION['form_opened'][$form] ?? null;
    unset($_SESSION['form_opened'][$form]);

    if (!is_int($opened)) {
        return false;
    }

    $elapsed = time() - $opened;

    if ($elapsed < MIN_FORM_SECONDS || $elapsed > MAX_FORM_SECONDS) {
        return false;
    }

    return trim((string) ($_POST['email'] ?? '')) === '';
}

/** The honeypot input. Rendered inside the form it protects. */
function honeypot_field(): string
{
    return '<input class="hp" type="text" name="email" value="" tabindex="-1"'
        . ' autocomplete="off" aria-hidden="true">';
}

/**
 * "3h ago". Whole units only — nobody needs the minutes on a two-day-old post.
 */
function ago(string $timestamp): string
{
    $seconds = max(0, time() - strtotime($timestamp));

    return match (true) {
        $seconds < 60          => 'just now',
        $seconds < 3600        => intdiv($seconds, 60) . 'm ago',
        $seconds < 86400       => intdiv($seconds, 3600) . 'h ago',
        $seconds < 86400 * 30  => intdiv($seconds, 86400) . 'd ago',
        default                => intdiv($seconds, 86400 * 30) . 'mo ago',
    };
}

/**
 * Render a view inside the shared layout.
 *
 * @param array<string,mixed> $vars
 */
function render(string $view, array $vars = []): void
{
    extract($vars, EXTR_SKIP);

    ob_start();
    require APP_DIR . '/views/' . $view . '.php';
    $content = ob_get_clean();

    require APP_DIR . '/views/layout.php';
}

load_env_file(ENV_FILE);
start_session();

require APP_DIR . '/auth.php';
require APP_DIR . '/youtube.php';
require APP_DIR . '/posts.php';
