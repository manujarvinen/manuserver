<?php
/**
 * One row of a feed. Included in a loop, so it reads $post from the caller.
 *
 * Every control is a real form posting to a real URL. The script in
 * public_html/app.js intercepts them and updates the row in place, but
 * nothing here depends on it having loaded.
 *
 * @var array<string,mixed> $post
 * @var string              $backTo  where an action should return to
 * @var bool                $hideLike
 */

declare(strict_types=1);

$mine = (int) $post['mine'] === 1;
$liked = (int) ($post['liked'] ?? 0) === 1;
$hidden = (int) ($post['hidden'] ?? 0) === 1;
$signedIn = current_user() !== null;
$showLike = empty($hideLike);

// Votes and reports need an account that has saved something. Rather than
// letting the click fail, the controls say why they are inert.
$canVote = $signedIn && has_saved_anything((int) current_user()['id']);
?>
<article class="item<?= $showLike ? '' : ' no-like' ?><?= $hidden ? ' is-hidden' : '' ?>">
  <?php if ($showLike): ?>
    <form class="like-form" method="post" action="/like">
      <?= csrf_field() ?>
      <input type="hidden" name="post" value="<?= (int) $post['id'] ?>">
      <input type="hidden" name="back" value="<?= h($backTo) ?>">
      <button type="submit" class="like-box<?= $liked ? ' liked' : '' ?>"
              data-like="<?= (int) $post['id'] ?>"
              <?php if ($mine): ?>disabled title="your own save"
              <?php elseif ($signedIn && !$canVote): ?>disabled title="save a video of your own first"
              <?php endif; ?>><?= $liked ? 'liked' : 'like' ?></button>
    </form>
  <?php endif; ?>

  <div class="post-body">
    <a class="title" href="<?= h(youtube_watch_url((string) $post['video_id'])) ?>"
       target="_blank" rel="noopener noreferrer nofollow"
       title="<?= h((string) $post['title']) ?>"><?= h((string) $post['title']) ?></a>

    <div class="meta">
      <span><strong data-like-count><?= (int) $post['likes'] ?></strong> likes</span>
      <span>by <?= $mine
        ? '<strong>you</strong>'
        : '<a class="nick" href="/u/' . h((string) $post['author']) . '">@' . h((string) $post['author']) . '</a>' ?></span>
      <span><?= h(ago((string) $post['created_at'])) ?></span>

      <?php if ($hidden): ?>
        <span class="warn">hidden by reports</span>
      <?php endif; ?>

      <?php if ($mine): ?>
        <form method="post" action="/delete" class="inline"
              onsubmit="return confirm('delete this save?')">
          <?= csrf_field() ?>
          <input type="hidden" name="post" value="<?= (int) $post['id'] ?>">
          <button type="submit" class="action">delete</button>
        </form>
      <?php elseif ($canVote): ?>
        <form method="post" action="/report" class="inline">
          <?= csrf_field() ?>
          <input type="hidden" name="post" value="<?= (int) $post['id'] ?>">
          <input type="hidden" name="back" value="<?= h($backTo) ?>">
          <button type="submit" class="action" data-report>report</button>
        </form>
      <?php endif; ?>
    </div>
  </div>
</article>
