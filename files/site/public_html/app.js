/*
 * app.js — makes the buttons feel instant. Nothing here is required.
 *
 * Every control on the page is already a form posting to a URL that works on
 * its own. This script intercepts four of them, posts the same form with
 * fetch, and updates the row from the JSON that comes back. If it fails to
 * load, fails to parse, or the request errors, the page keeps working exactly
 * as it did before — the fallback is the real behaviour, not a degraded one.
 */

(() => {
  'use strict';

  const handlers = {
    '/like': applyLike,
    '/rep': applyRep,
    '/follow': applyFollow,
    '/report': applyReport,
  };

  document.addEventListener('submit', (event) => {
    const form = event.target;

    if (!(form instanceof HTMLFormElement)) return;

    const handler = handlers[form.getAttribute('action')];
    if (!handler) return;

    event.preventDefault();

    send(form)
      .then((data) => handler(form, data))
      // Whatever went wrong, the plain form post still works. Submitting
      // programmatically skips this listener, so there is no loop.
      .catch(() => form.submit());
  });

  async function send(form) {
    const response = await fetch(form.action, {
      method: 'POST',
      headers: { Accept: 'application/json' },
      body: new FormData(form),
      credentials: 'same-origin',
    });

    if (!response.ok) throw new Error(String(response.status));

    return response.json();
  }

  function applyLike(form, data) {
    const button = form.querySelector('[data-like]');
    if (!button) throw new Error('no button');

    button.classList.toggle('liked', data.liked);
    button.textContent = data.liked ? 'liked' : 'like';

    const count = form.closest('.item')?.querySelector('[data-like-count]');
    if (count) count.textContent = String(data.likes);
  }

  function applyRep(form, data) {
    const button = form.querySelector('[data-rep]');
    if (!button) throw new Error('no button');

    button.classList.toggle('given', data.given);
    button.textContent = data.given ? 'rep given' : 'give rep';

    const count = form.closest('.panel')?.querySelector('[data-rep-count]');
    if (count) count.textContent = String(data.reputation);
  }

  function applyFollow(form, data) {
    const button = form.querySelector('[data-follow]');
    if (!button) throw new Error('no button');

    button.textContent = data.following ? 'unfollow' : 'follow';
  }

  function applyReport(form) {
    // Reporting is one-way, so the control is spent once it is used.
    const note = document.createElement('span');
    note.textContent = 'reported';
    form.replaceWith(note);
  }

  // --- the reputation slider ---------------------------------------------
  //
  // Without this the slider is a GET form with an "apply" button. With it,
  // the number tracks the handle and releasing it reloads, so the button is
  // redundant and gets hidden.
  const range = document.getElementById('rep');

  if (range) {
    const readout = document.getElementById('repval');
    const apply = document.querySelector('.range-apply');

    if (apply) apply.hidden = true;

    range.addEventListener('input', () => {
      if (readout) readout.value = range.value;
    });

    range.addEventListener('change', () => range.form.submit());
  }

  // --- copying the account key -------------------------------------------
  document.addEventListener('click', (event) => {
    const button = event.target.closest('[data-copy]');
    if (!button) return;

    const source = document.getElementById(button.dataset.copy);
    if (!source) return;

    const done = () => {
      button.textContent = 'copied';
      setTimeout(() => { button.textContent = 'copy'; }, 2000);
    };

    // The clipboard API needs a secure context. Over plain http on a local
    // network it is simply absent, so fall back to selecting the key and
    // letting the reader copy it themselves.
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(source.textContent.trim()).then(done, selectKey);
    } else {
      selectKey();
    }

    function selectKey() {
      const range = document.createRange();
      range.selectNodeContents(source);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      button.textContent = 'press ctrl-c';
    }
  });
})();
