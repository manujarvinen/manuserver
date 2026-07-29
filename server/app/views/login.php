<?php
/**
 * @var string|null $error
 */

declare(strict_types=1);
?>
<section class="block form-block">
  <?php if (!empty($error)): ?>
    <p class="warn"><?= h($error) ?></p>
  <?php else: ?>
    <p class="note">paste the key you were given. spaces and line breaks from wherever you kept it are fine.</p>
  <?php endif; ?>

  <form method="post" action="/login" class="stack">
    <?= csrf_field() ?>

    <label class="field">
      <span>your key</span>
      <textarea name="key" rows="2" required autofocus autocomplete="off" spellcheck="false"></textarea>
    </label>

    <button type="submit" class="framed-action">sign in</button>
  </form>

  <p class="note">lost it? there is no recovery — <a class="action" href="/join">start a new account</a>.</p>
</section>
