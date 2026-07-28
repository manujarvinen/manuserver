<?php
// The school project goes here.
//
// This folder is what the server puts on the web. Once provision.sh installs
// nginx, this file is what people see when they visit the server.
//
// The connection details below are read from the environment so no password
// is ever written into a file that goes into git.

$status = 'not connected yet';
$detail = 'Postgres is not installed on the server yet.';

try {
    $db = new PDO(
        sprintf(
            'pgsql:host=%s;dbname=%s',
            getenv('DB_HOST') ?: 'localhost',
            getenv('DB_NAME') ?: 'manuserver'
        ),
        getenv('DB_USER') ?: 'manuserver',
        getenv('DB_PASSWORD') ?: '',
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
    $status = 'connected';
    $detail = $db->query('SELECT version()')->fetchColumn();
} catch (Throwable $e) {
    $detail = $e->getMessage();
}
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>manuserver</title>
<style>
  body {
    margin: 0;
    min-height: 100vh;
    display: grid;
    place-items: center;
    padding: 2rem;
    background: #2E1522;
    color: #A81558;
    font: 1rem/1.6 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  main { max-width: 34rem; }
  h1 { margin: 0 0 1.5rem; color: #8F0B45; letter-spacing: 0.12em; }
  .label { color: #E81E80; }
  .detail { color: #7A1040; font-size: 0.875rem; word-break: break-word; }
</style>
</head>
<body>
  <main>
    <h1>MANUSERVER</h1>
    <p><span class="label">database:</span> <?= htmlspecialchars($status) ?></p>
    <p class="detail"><?= htmlspecialchars($detail) ?></p>
  </main>
</body>
</html>
