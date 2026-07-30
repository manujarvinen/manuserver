// offline-worker-test.mjs — checks the one piece of code that sits in front of
// a working site.
//
// Run it:  node files/dev/offline-worker-test.mjs
//
// Needs node 22 or newer and nothing else — no package.json, no install. The
// Worker is a `.js` file written as a module, which node detects on its own
// from that version. It imports the
// Worker unmodified, stubs global fetch to be the origin, and asks what a
// visitor would get. The status rules are the whole risk: intercept too much
// and a broken site looks switched off, intercept too little and a switched-off
// server shows Cloudflare's 1033.

import worker from '../deploy/offline-worker.js';
import { readFileSync } from 'node:fs';

let pass = 0, fail = 0;
const ok = (cond, name) => { cond ? pass++ : (fail++, console.log('  FAIL ' + name)); };

const req = () => new Request('https://tastehopping.com/');

// Origin answered with `status`; what does the visitor get?
async function through(status) {
  globalThis.fetch = async () => new Response('origin body', { status });
  return worker.fetch(req());
}

// Codes that mean "Cloudflare could not reach the origin" -> our page.
for (const s of [502, 504, 520, 521, 522, 523, 524, 525, 526, 527, 528, 529, 530]) {
  const r = await through(s);
  ok(r.status === 503, `${s} should become the offline page (got ${r.status})`);
}

// Everything else must pass through untouched, including 5xx from PHP.
for (const s of [200, 301, 404, 418, 500, 501, 503, 505, 519, 531, 599]) {
  const r = await through(s);
  ok(r.status === s, `${s} should pass through (got ${r.status})`);
  if (s !== 503) ok((await r.text()) === 'origin body', `${s} body should be the origin's`);
}

// The subrequest itself throwing is also "unreachable".
globalThis.fetch = async () => { throw new Error('tunnel down'); };
const thrown = await worker.fetch(req());
ok(thrown.status === 503, 'a thrown subrequest should become the offline page');

// The page itself.
const page = await through(502);
const body = await page.text();
ok(page.headers.get('content-type').startsWith('text/html'), 'content-type is html');
ok(page.headers.get('cache-control') === 'no-store', 'not cached');
ok(page.headers.get('retry-after') === '3600', 'retry-after set');
// Nothing the page needs in order to render may come from off-box. An <a href>
// is fine - it is a link the reader may follow, not a request the browser makes.
ok(!/<(script|link|img|iframe|video|audio|source)\b/i.test(body), 'no asset-fetching tags');
ok(!/\bsrc\s*=/i.test(body), 'no src attributes');
ok(!/@import|url\(\s*['\"]?https?:/i.test(body), 'no external CSS fetches');
const hrefs = [...body.matchAll(/href\s*=\s*"([^"]*)"/gi)].map((m) => m[1]);
ok(hrefs.every((h) => /^https:\/\/github\.com\//.test(h)), 'the only href is the github link: ' + JSON.stringify(hrefs));

// The inlined wordmark must still match files/promo/manuserver.svg.
const d = (t) => (t.match(/(?:^|\s)d="([^"]*)"/) || [])[1];
const svg = readFileSync(new URL('../promo/manuserver.svg', import.meta.url), 'utf8');
ok(d(body) === d(svg), 'inlined wordmark matches the SVG');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
