<?php
/**
 * The reputation filter under the feeds.
 *
 * It is a GET form, so it works as a plain page reload with the "apply"
 * button. The script hides that button and reloads on release instead.
 *
 * @var int $rep
 */

declare(strict_types=1);
?>
<form class="range" method="get" action="">
  <div class="range-head">
    <label for="rep">user reputation</label>
    <output id="repval" for="rep"><?= (int) $rep ?></output>
  </div>
  <input id="rep" name="rep" type="range" min="0" max="1000" step="10" value="<?= (int) $rep ?>">
  <div class="scale"><span>0</span><span>1000</span></div>
  <button type="submit" class="framed-action range-apply">apply</button>
</form>
