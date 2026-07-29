<?php
/**
 * @var string|null $error
 */

declare(strict_types=1);
?>
<section class="block form-block">
  <?php if (!empty($error)): ?>
    <p class="warn"><?= h($error) ?></p>
  <?php endif; ?>

  <p class="note">joining asks for nothing. press the button and you get a name and one long key.</p>

  <p class="note">the key <em>is</em> the account, shown only on the next screen. copy it somewhere
  safe — only a hash is kept, so a lost key means a new name.</p>

  <form method="post" action="/join" class="stack">
    <?= csrf_field() ?>
    <?= honeypot_field() ?>
    <button type="submit" class="framed-action">make me an account</button>
  </form>

  <p class="note">unused for three months and an account is deleted, saves included — and there is no
  email here to warn you first. visiting keeps one alive.</p>

  <p class="note">already have a key? <a class="action" href="/login">sign in with it</a>.</p>
</section>
