<?php
/**
 * @var list<array<string,mixed>> $posts
 * @var int                       $rep
 * @var string                    $activeView
 */

declare(strict_types=1);

$backTo = '/' . $activeView;

$emptyText = match ($activeView) {
    'follows' => current_user() === null
        ? 'follows are per account. join, then click a name to follow it.'
        : 'follow a few people to build this feed. the reputation filter still applies to follows.',
    default   => 'nothing saved in this part of the range yet. move the slider, or be the first.',
};
?>
<?php if ($posts === []): ?>
  <section class="block empty">
    <p><?= h($emptyText) ?></p>
    <?php require APP_DIR . '/views/slider.php'; ?>
  </section>
<?php else: ?>
  <section class="block">
    <div class="list">
      <?php foreach ($posts as $post): ?>
        <?php require APP_DIR . '/views/item.php'; ?>
      <?php endforeach; ?>
    </div>
    <?php require APP_DIR . '/views/slider.php'; ?>
  </section>
<?php endif; ?>
