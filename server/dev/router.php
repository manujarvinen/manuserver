<?php
// router.php — nginx's try_files, for PHP's built-in development server.
//
// The built-in server has no rewrite rules: it serves a file if the path
// names one and 404s otherwise. This hands back false for real files, which
// makes the server deliver them itself, and sends everything else to the
// front controller — the same two-line rule the nginx config uses.
//
// Development only. It is never on the actual server.

declare(strict_types=1);

$docroot = dirname(__DIR__, 2) . '/public_html';
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$file = $docroot . $path;

if ($path !== '/' && is_file($file)) {
    return false;
}

require $docroot . '/index.php';
