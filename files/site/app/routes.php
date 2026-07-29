<?php
// routes.php — one function per URL, and the switch that picks between them.

declare(strict_types=1);

/** Where the reputation slider sits before anyone has touched it. */
const DEFAULT_REP = 500;

/** The feeds that are just a list of posts with a slider under them. */
const FEED_VIEWS = ['new', 'popular', 'random', 'follows'];

function dispatch(): void
{
    $path = '/' . trim(parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '', '/');
    $isPost = ($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST';

    // Checked before anything is read or written, for every POST there is.
    if ($isPost) {
        require_csrf();
    }

    // The slider setting rides along in the session so it survives clicking
    // between feeds — it is a mood, not a property of one page.
    if (isset($_GET['rep'])) {
        $_SESSION['rep'] = max(0, min(1000, (int) $_GET['rep']));
    }

    $rep = (int) ($_SESSION['rep'] ?? DEFAULT_REP);

    if (!$isPost) {
        $view = ltrim($path, '/');

        if ($path === '/' || $view === 'what') {
            show_what();
            return;
        }

        if (in_array($view, FEED_VIEWS, true)) {
            show_feed($view, $rep);
            return;
        }

        if (preg_match('~^/u/([a-z]{2,4}-[a-z]{2,4})$~', $path, $match)) {
            show_profile($match[1]);
            return;
        }

        switch ($path) {
            case '/you':     show_you();     return;
            case '/add':     show_add();     return;
            case '/join':    show_join();    return;
            case '/welcome': show_welcome(); return;
            case '/login':   show_login();   return;
            case '/export':  do_export();    return;
        }
    }

    if ($isPost) {
        switch ($path) {
            case '/add':    do_add();    return;
            case '/join':   do_join();   return;
            case '/login':  do_login();  return;
            case '/logout': do_logout(); return;
            case '/like':   do_like();   return;
            case '/rep':    do_rep();    return;
            case '/follow': do_follow(); return;
            case '/report': do_report(); return;
            case '/delete': do_delete(); return;
        }
    }

    not_found();
}

// --- helpers ---------------------------------------------------------------

/**
 * Where to send the browser back to after an action.
 *
 * Only same-site paths are honoured. A "back" value is attacker-controllable
 * by construction — it arrives in a form post — so anything that is not a
 * plain absolute path on this host is discarded rather than turned into an
 * open redirect.
 */
function safe_back(string $fallback = '/new'): string
{
    $back = $_POST['back'] ?? '';

    if (is_string($back) && preg_match('~^/[^/\\\\]~', $back)) {
        return $back;
    }

    return $fallback;
}

/** True when the caller is the page's JavaScript rather than a form post. */
function wants_json(): bool
{
    return str_contains($_SERVER['HTTP_ACCEPT'] ?? '', 'application/json');
}

/** @param array<string,mixed> $data */
function send_json(array $data): never
{
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function not_found(): never
{
    http_response_code(404);
    render('message', [
        'activeView' => '',
        'heading'    => 'nothing here',
        'body'       => 'that address does not lead anywhere on this site.',
    ]);
    exit;
}

// --- pages -----------------------------------------------------------------

function show_what(): void
{
    render('what', ['activeView' => 'what']);
}

function show_feed(string $view, int $rep): void
{
    render('feed', [
        'activeView' => $view,
        'posts'      => feed_posts($view, current_user_id(), $rep),
        'rep'        => $rep,
        'user'       => current_user(),
    ]);
}

function show_you(): void
{
    $user = require_user();
    $page = max(0, (int) ($_GET['page'] ?? 0));
    $userId = (int) $user['id'];

    render('profile', [
        'activeView' => 'you',
        'self'       => true,
        'profile'    => $user,
        'posts'      => posts_by_user($userId, $userId, $page, true),
        'page'       => $page,
        'total'      => post_count_for_user($userId, true),
        'user'       => $user,
    ]);
}

function show_profile(string $name): void
{
    $profile = user_by_name($name);

    if ($profile === null) {
        not_found();
    }

    $viewer = current_user();
    $viewerId = $viewer === null ? null : (int) $viewer['id'];
    $profileId = (int) $profile['id'];

    // Your own name in the address bar is the same page as "you".
    if ($viewerId === $profileId) {
        redirect('/you');
    }

    $page = max(0, (int) ($_GET['page'] ?? 0));

    render('profile', [
        'activeView' => '',
        'self'       => false,
        'profile'    => $profile,
        'posts'      => posts_by_user($profileId, $viewerId, $page, false),
        'page'       => $page,
        'total'      => post_count_for_user($profileId, false),
        'user'       => $viewer,
        'following'  => $viewerId !== null && follows($viewerId, $profileId),
        'repGiven'   => $viewerId !== null && gave_rep($viewerId, $profileId),
    ]);
}

function show_add(): void
{
    require_user();

    render('add', [
        'activeView' => 'add',
        'link'       => '',
        'title'      => '',
        'user'       => current_user(),
    ]);
}

/**
 * Saving a video happens in two passes.
 *
 * The first pass has only a link: the title is fetched from YouTube and the
 * form comes back with it filled in, so the poster sees what they are about
 * to save and can rewrite it. The second pass, with a title present, is the
 * one that writes a row.
 */
function do_add(): void
{
    $user = require_user();
    $link = trim((string) ($_POST['link'] ?? ''));
    $title = trim((string) ($_POST['title'] ?? ''));
    $videoId = youtube_video_id($link);

    $fail = static function (string $message, string $link, string $title): never {
        render('add', [
            'activeView' => 'add',
            'error'      => $message,
            'link'       => $link,
            'title'      => $title,
            'user'       => current_user(),
        ]);
        exit;
    };

    if ($videoId === null) {
        $fail('that does not look like a youtube link.', $link, $title);
    }

    if ($title === '') {
        $fetched = youtube_title($videoId);

        if ($fetched === null) {
            $fail(
                'could not read the title from youtube — the video may be private, '
                . 'or the server may be offline. write a title yourself and save.',
                $link,
                ''
            );
        }

        render('add', [
            'activeView' => 'add',
            'notice'     => 'found it. change the title if you like, then save.',
            'link'       => $link,
            'title'      => $fetched,
            'user'       => $user,
        ]);
        return;
    }

    $title = trim_title($title);

    if ($title === '') {
        $fail('a title cannot be empty.', $link, '');
    }

    if (create_post((int) $user['id'], $videoId, $title) === null) {
        $fail('you have already saved that one.', $link, $title);
    }

    flash('saved.');
    redirect('/you');
}

function show_join(): void
{
    if (current_user() !== null) {
        redirect('/you');
    }

    render('join', ['activeView' => 'join']);
}

function do_join(): void
{
    if (current_user() !== null) {
        redirect('/you');
    }

    $account = create_account();
    log_in($account['id']);

    // The key goes into the session for exactly one page view. It is never
    // written to the database in a form that can be read back, so this is the
    // only moment it exists anywhere the site can reach.
    $_SESSION['fresh_key'] = $account['key'];
    $_SESSION['fresh_name'] = $account['name'];

    redirect('/welcome');
}

function show_welcome(): void
{
    $key = $_SESSION['fresh_key'] ?? null;
    $name = $_SESSION['fresh_name'] ?? null;
    unset($_SESSION['fresh_key'], $_SESSION['fresh_name']);

    if (!is_string($key) || !is_string($name)) {
        redirect('/you');
    }

    render('welcome', ['activeView' => '', 'key' => $key, 'name' => $name]);
}

function show_login(): void
{
    if (current_user() !== null) {
        redirect('/you');
    }

    render('login', ['activeView' => 'join']);
}

function do_login(): void
{
    $account = account_for_key((string) ($_POST['key'] ?? ''));

    if ($account === null) {
        // The same message whether the key was malformed or simply unknown.
        render('login', [
            'activeView' => 'join',
            'error'      => 'no account has that key.',
        ]);
        return;
    }

    log_in((int) $account['id']);
    touch_last_seen((int) $account['id']);
    redirect('/you');
}

function do_logout(): never
{
    log_out();
    flash('signed out. the key is the only way back in.');
    redirect('/what');
}

// --- actions ---------------------------------------------------------------

function do_like(): never
{
    $user = require_user();
    $postId = (int) ($_POST['post'] ?? 0);
    $liked = toggle_like($postId, (int) $user['id']);

    if (wants_json()) {
        send_json(['liked' => $liked, 'likes' => like_count($postId)]);
    }

    redirect(safe_back());
}

function do_rep(): never
{
    $user = require_user();
    $subject = user_by_name((string) ($_POST['user'] ?? ''));

    if ($subject === null) {
        not_found();
    }

    $given = toggle_rep((int) $user['id'], (int) $subject['id']);

    if (wants_json()) {
        send_json(['given' => $given, 'reputation' => reputation_of((int) $subject['id'])]);
    }

    redirect(safe_back('/u/' . $subject['name']));
}

function do_follow(): never
{
    $user = require_user();
    $subject = user_by_name((string) ($_POST['user'] ?? ''));

    if ($subject === null) {
        not_found();
    }

    $following = toggle_follow((int) $user['id'], (int) $subject['id']);

    if (wants_json()) {
        send_json(['following' => $following]);
    }

    redirect(safe_back('/u/' . $subject['name']));
}

function do_report(): never
{
    $user = require_user();
    report_post((int) ($_POST['post'] ?? 0), (int) $user['id']);

    if (wants_json()) {
        send_json(['reported' => true]);
    }

    flash('reported. enough reports and it stops showing up.');
    redirect(safe_back());
}

function do_delete(): never
{
    $user = require_user();

    flash(delete_post((int) ($_POST['post'] ?? 0), (int) $user['id'])
        ? 'deleted.'
        : 'that is not yours to delete.');

    redirect('/you');
}

function do_export(): never
{
    $user = require_user();

    header('Content-Type: application/json; charset=utf-8');
    header('Content-Disposition: attachment; filename="tastehopping-' . $user['name'] . '.json"');
    echo json_encode(export_account((int) $user['id']), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}
