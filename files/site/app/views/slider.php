<?php
/**
 * The reputation filter under the feeds.
 *
 * It is a GET form, so it works as a plain page reload with the "apply"
 * button. The script hides that button and reloads on release instead.
 *
 * The handle is a floor, so the label says so. "user reputation" alone reads
 * as "show me people around here", which is not what it does: at 600 you get
 * everyone from 600 up, and at 0 you get everyone.
 *
 * @var int $rep
 */

declare(strict_types=1);
?>
<form class="range" method="get" action="">
  <div class="range-head">
    <label for="rep">minimum user reputation</label>
    <output id="repval" for="rep"><?= (int) $rep ?></output>
  </div>
  <input id="rep" name="rep" type="range" min="0" max="1000" step="10" value="<?= (int) $rep ?>">
  <div class="scale"><span>0</span><span>1000</span></div>
  <button type="submit" class="framed-action range-apply">apply</button>
</form>
