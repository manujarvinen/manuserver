<?php
/**
 * One person's saves, plus the panel of things you can do about them.
 *
 * @var bool                      $self
 * @var array<string,mixed>       $profile
 * @var list<array<string,mixed>> $posts
 * @var int                       $page
 * @var int                       $total
 * @var bool                      $following  others only
 * @var bool                      $repGiven   others only
 */

declare(strict_types=1);

$name = (string) $profile['name'];
$backTo = $self ? '/you' : '/u/' . $name;
$backTo .= $page > 0 ? '?page=' . $page : '';

// On your own page the like column is dead weight — every row is yours.
$hideLike = $self;
$more = ($page + 1) * PAGE_SIZE < $total;
$signedIn = current_user() !== null;

// Reputation is a vote, so it waits on the same thing likes and reports do.
// Following does not — it only changes what you yourself see.
$canVote = $signedIn && has_saved_anything((int) current_user()['id']);
?>
<section class="block">
  <?php if ($posts === []): ?>
    <p class="empty"><?= $self
      ? 'you have not saved anything yet. <a class="action" href="/add">add one</a>.'
      : 'nothing here yet.' ?></p>
  <?php else: ?>
    <div class="list">
      <?php foreach ($posts as $post): ?>
        <?php require APP_DIR . '/views/item.php'; ?>
      <?php endforeach; ?>
    </div>
  <?php endif; ?>

  <?php if ($more): ?>
    <a class="more" href="<?= h(($self ? '/you' : '/u/' . $name) . '?page=' . ($page + 1)) ?>">more</a>
  <?php endif; ?>

  <div class="panel">
    <span class="panel-line">
      <?php if ($self): ?>
        <span><strong>you</strong> · <span data-rep-count><?= (int) $profile['reputation'] ?></span> rep · <?= (int) $total ?> saved</span>
        <a class="action" href="/export">export</a>
        <form method="post" action="/logout" class="inline">
          <?= csrf_field() ?>
          <button type="submit" class="action">sign out</button>
        </form>
      <?php else: ?>
        <span>@<?= h($name) ?> · <span data-rep-count><?= (int) $profile['reputation'] ?></span> rep · <?= (int) $total ?> saved</span>

        <?php if ($signedIn): ?>
          <?php if ($canVote): ?>
            <form method="post" action="/rep" class="inline">
              <?= csrf_field() ?>
              <input type="hidden" name="user" value="<?= h($name) ?>">
              <input type="hidden" name="back" value="<?= h($backTo) ?>">
              <button type="submit" class="framed-action<?= $repGiven ? ' given' : '' ?>" data-rep><?= $repGiven ? 'rep given' : 'give rep' ?></button>
            </form>
          <?php else: ?>
            <a class="action" href="/add">save a video to give rep</a>
          <?php endif; ?>

          <form method="post" action="/follow" class="inline">
            <?= csrf_field() ?>
            <input type="hidden" name="user" value="<?= h($name) ?>">
            <input type="hidden" name="back" value="<?= h($backTo) ?>">
            <button type="submit" class="action" data-follow><?= $following ? 'unfollow' : 'follow' ?></button>
          </form>
        <?php else: ?>
          <a class="action" href="/join">join to follow</a>
        <?php endif; ?>
      <?php endif; ?>
    </span>
  </div>
</section>
