<?php
/**
 * The page around every page.
 *
 * @var string      $content    rendered view
 * @var string      $activeView nav item to mark current, '' for none
 * @var string|null $pageTitle
 */

declare(strict_types=1);

$signedIn = current_user() !== null;

// Signed out, half the nav would only lead to a sign-up prompt, so it is not
// offered. "join" takes its place.
$navItems = $signedIn
    ? ['what' => '/what', 'new' => '/new', 'popular' => '/popular', 'random' => '/random',
       'follows' => '/follows', 'you' => '/you', 'add' => '/add']
    : ['what' => '/what', 'new' => '/new', 'popular' => '/popular', 'random' => '/random',
       'join' => '/join'];

$message = take_flash();
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title><?= h($pageTitle ?? 'tastehopping') ?></title>
<meta name="referrer" content="no-referrer">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<div class="shell">
  <header class="top">
    <a href="/what" class="brand">tastehopping</a>
  </header>

  <nav class="nav" aria-label="Primary">
    <?php foreach ($navItems as $label => $href): ?>
      <a href="<?= h($href) ?>"<?= $label === ($activeView ?? '') ? ' class="active" aria-current="page"' : '' ?>><?= h($label) ?></a>
    <?php endforeach; ?>
  </nav>

  <?php if ($message !== null): ?>
    <p class="flash"><?= h($message) ?></p>
  <?php endif; ?>

  <main class="feed"><?= $content ?></main>
</div>
<script src="/app.js"></script>
</body>
</html>
