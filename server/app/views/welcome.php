<?php
/**
 * Shown once, immediately after signing up, and never again.
 *
 * @var string $name
 * @var string $key
 */

declare(strict_types=1);
?>
<section class="block form-block">
  <p class="note">you are <strong><?= h($name) ?></strong>, and you are signed in.</p>

  <p class="warn">this is the only time this key is shown. save it now.</p>

  <div class="keybox">
    <code id="account-key"><?= h($key) ?></code>
    <button type="button" class="framed-action" data-copy="account-key">copy</button>
  </div>

  <p class="note">paste it into a note, a password manager, or an email to yourself. it is the only way
  back into this account — the server stored a hash of it and cannot show it again or send it to you,
  because it does not know who you are.</p>

  <p class="note"><a class="action" href="/add">save your first video</a>, or <a class="action" href="/new">look at what other people saved</a>.</p>
</section>
