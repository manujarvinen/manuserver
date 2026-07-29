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

  <p class="note">joining asks you for nothing. press the button and the server invents a name for you
  and hands you one key. no email, no password, no name of your own.</p>

  <p class="note">the key is the whole account. the next screen is the only place it is ever shown —
  copy it somewhere safe, or mail it to yourself. the server keeps only a hash of it, so if it is lost
  there is nothing to recover and you start again with a new name.</p>

  <form method="post" action="/join" class="stack">
    <?= csrf_field() ?>
    <?= honeypot_field() ?>
    <button type="submit" class="framed-action">make me an account</button>
  </form>

  <p class="note">already have a key? <a class="action" href="/login">sign in with it</a>.</p>
</section>
