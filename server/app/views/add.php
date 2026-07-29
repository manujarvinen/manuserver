<?php
/**
 * @var string      $link
 * @var string      $title
 * @var string|null $error
 * @var string|null $notice
 */

declare(strict_types=1);
?>
<section class="block form-block">
  <?php if (!empty($error)): ?>
    <p class="warn"><?= h($error) ?></p>
  <?php elseif (!empty($notice)): ?>
    <p class="note"><?= h($notice) ?></p>
  <?php else: ?>
    <p class="note">paste a youtube link. the title comes from youtube, and you can rewrite it before saving.</p>
  <?php endif; ?>

  <form method="post" action="/add" class="stack">
    <?= csrf_field() ?>

    <label class="field">
      <span>youtube link</span>
      <input type="text" name="link" value="<?= h($link) ?>" required autofocus
             placeholder="https://www.youtube.com/watch?v=…" autocomplete="off" spellcheck="false">
    </label>

    <label class="field">
      <span>title<?= $title === '' ? ' — leave empty to fetch it' : '' ?></span>
      <input type="text" name="title" value="<?= h($title) ?>" maxlength="120"
             placeholder="fetched from youtube" autocomplete="off">
    </label>

    <button type="submit" class="framed-action"><?= $title === '' ? 'look it up' : 'save' ?></button>
  </form>
</section>
