// offline-worker.js — what tastehopping.com shows when the server is off.
//
// Runs on Cloudflare's edge, on a route covering the site. It passes every
// request through to the tunnel untouched, and only steps in when the tunnel
// cannot be reached — because the machine at home is switched off, which for a
// server that lives in someone's flat is a normal Tuesday rather than an
// outage.
//
// Without it, visitors get Cloudflare's error 1033: grey, branded, and worded
// as though the site is broken.
//
// Deploying it is in INSTALL.md. Keeping the source here rather than in a
// dashboard text box is the same reasoning that put the nginx config in
// provision.sh — the thing people see should be reviewable and in git.
//
// The cost, stated plainly: this is code in front of a working system, to
// handle the case where the system is not working. A mistake in here takes the
// site down even when the server is up. Keep it boring.

export default {
  async fetch(request) {
    try {
      const response = await fetch(request);
      return unreachable(response.status) ? offline() : response;
    } catch {
      // The subrequest itself failed. Nothing to pass on, so this is us.
      return offline();
    }
  },
};

// Only the codes that mean "Cloudflare could not reach the origin".
//
// Deliberately not every 5xx: a 500 from PHP means the server answered and the
// site is broken, which is a different thing and should look like one. 502 and
// 504 are here because nginx up with php-fpm down produces them, and that is
// as good as off from a visitor's side.
const unreachable = (status) =>
  status === 502 || status === 504 || (status >= 520 && status <= 530);

const offline = () =>
  new Response(PAGE, {
    // 503, not 200. It tells crawlers this is temporary and not to drop the
    // site, and Retry-After tells them roughly when to bother again.
    status: 503,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'retry-after': '3600',
    },
  });

// Inline, so the page needs nothing from anywhere — no stylesheet, no font, no
// image. It has to render on the one occasion the origin cannot be reached, so
// depending on a second request would be an odd way to build it.
const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>tastehopping — back shortly</title>
<style>
  :root {
    --bg: #2E1522;
    --logo: #8F0B45;
    --body: #C4738F;
    --heading: #E81E80;
    --dim: #8A4A63;
  }
  * { box-sizing: border-box }
  body {
    margin: 0;
    min-height: 100vh;
    display: grid;
    place-items: center;
    padding: 2rem 1.25rem;
    background: var(--bg);
    color: var(--body);
    font: 1rem/1.7 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  }
  main { max-width: 30rem }
  svg { display: block; width: 100%; height: auto; fill: var(--logo) }
  h1 {
    margin: 1.75rem 0 1rem;
    color: var(--heading);
    font-size: 1.25rem;
    font-weight: 700;
  }
  p { margin: 0 0 1rem }
  .note { margin-top: 2rem; color: var(--dim); font-size: 0.9375rem }
  a { color: var(--heading) }
</style>
</head>
<body>
<main>
  <svg viewBox="0 0 1000 95" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="MANUSERVER">
    <path d="M 0,46.085858 V 0 h 15.151517 15.151518 v 5.6818184 5.6818186 h 5.050497 5.050523 v 4.419191 4.419192 h 5.050497 5.050498 v 5.681818 5.681819 H 60.60607 70.707089 V 25.883838 20.20202 h 5.050498 5.050498 v -4.419192 -4.419191 h 5.050497 5.050522 V 5.6818184 0 h 15.151516 15.15152 V 46.085858 92.171716 H 106.06062 90.909104 V 66.287881 40.40404 h -5.050522 -5.050497 v 5.681818 5.681819 h -5.050498 -5.050498 v 4.419189 4.419196 H 60.60607 50.50505 V 56.186866 51.767677 H 45.454552 40.404055 V 46.085858 40.40404 H 35.353532 30.303035 V 66.287881 92.171716 H 15.151517 0 Z M 131.31313,56.186866 V 20.20202 h 5.0505 5.05052 v -4.419192 -4.419191 h 5.0505 5.0505 V 5.6818184 0 h 20.20204 20.20201 v 5.6818184 5.6818186 h 5.0505 5.0505 v 4.419191 4.419192 h 5.05052 5.0505 v 35.984846 35.98485 H 196.9697 181.81818 V 76.388886 60.606062 h -10.10099 -10.10102 v 15.782824 15.78283 H 146.46465 131.31313 Z M 181.81818,35.984848 V 20.20202 h -10.10099 -10.10102 v 15.782828 15.782829 h 10.10102 10.10099 z m 40.40406,10.10101 V 0 h 15.15152 15.15149 v 5.6818184 5.6818186 h 5.05052 5.0505 v 4.419191 4.419192 h 5.0505 5.05052 v 5.681818 5.681819 h 5.0505 5.05049 v 4.419191 4.419192 h 5.05053 5.05049 V 20.20202 0 h 15.15152 15.15152 V 46.085858 92.171716 H 308.08082 292.9293 V 82.070704 71.969699 h -5.05049 -5.05053 v -5.681818 -5.681819 h -5.05049 -5.0505 v -4.419196 -4.419189 h -5.05052 -5.0505 V 46.085858 40.40404 h -5.0505 -5.05052 v 25.883841 25.883835 h -15.15149 -15.15152 z m 121.21211,40.40404 V 80.80808 h -5.05049 -5.0505 V 40.40404 0 h 15.15152 15.15149 v 30.30303 30.303032 h 10.10102 10.10102 V 30.30303 0 h 15.15152 15.15151 v 40.40404 40.40404 h -5.05052 -5.0505 v 5.681818 5.681818 h -30.30303 -30.30304 z m 80.80809,-4.419194 V 71.969699 h 20.20204 20.20201 v -5.681818 -5.681819 h -5.05052 -5.0505 v -4.419196 -4.419189 h -5.0505 -5.05049 V 46.085858 40.40404 h -5.05052 -5.0505 v -4.419192 -4.419191 h -5.0505 -5.05052 v -10.10101 -10.10101 h 5.05052 5.0505 V 5.6818184 0 h 35.35353 35.35353 V 10.10101 20.20202 H 489.899 474.74749 v 5.681818 5.681819 h 5.05052 5.0505 v 4.419191 4.419192 h 5.05049 5.05053 v 5.681818 5.681819 h 5.05049 5.0505 V 66.287881 80.80808 h -5.0505 -5.05049 v 5.681818 5.681818 h -35.35356 -35.35353 z m 101.0101,4.419194 V 80.80808 h -5.0505 -5.0505 V 46.085858 11.363637 h 5.0505 5.0505 V 5.6818184 0 h 35.35353 35.35356 v 10.10101 10.10101 h -25.25254 -25.25251 v 10.10101 10.10101 h 10.10099 10.10102 v 5.681818 5.681819 h -10.10102 -10.10099 v 10.101007 10.101015 h 25.25251 25.25254 v 10.101005 10.101012 h -35.35356 -35.35353 z m 80.80808,-40.40404 V 0 h 35.35353 35.35354 v 5.6818184 5.6818186 h 5.05052 5.0505 v 4.419191 4.419192 h 5.05049 5.05053 v 10.10101 10.10101 h -5.05053 -5.05049 v 5.681818 5.681819 h -5.0505 -5.05052 v 4.419189 4.419196 h 5.05052 5.0505 v 5.681819 5.681818 h 5.05049 5.05053 V 82.070704 92.171716 H 681.81821 666.66669 V 86.489898 80.80808 h -5.05052 -5.0505 V 70.707067 60.606062 h -10.10099 -10.10102 v 15.782824 15.78283 H 621.21214 606.06062 Z M 656.56567,30.30303 V 20.20202 h -10.10099 -10.10102 v 10.10101 10.10101 h 10.10102 10.10099 z m 80.80809,56.186868 V 80.80808 h -5.0505 -5.0505 v -4.419194 -4.419187 h -5.05052 -5.0505 V 46.085858 20.20202 h -5.05052 -5.0505 V 10.10101 0 h 20.20204 20.20202 v 30.30303 30.303032 h 10.10099 10.10102 V 30.30303 0 h 20.20202 20.20201 v 10.10101 10.10101 h -5.0505 -5.05049 v 25.883838 25.883841 h -5.05053 -5.05049 v 4.419187 4.419194 h -5.0505 -5.05052 v 5.681818 5.681818 h -20.20202 -20.20201 z m 90.9091,0 V 80.80808 h -5.05052 -5.0505 V 46.085858 11.363637 h 5.0505 5.05052 V 5.6818184 0 h 35.35353 35.35354 v 10.10101 10.10101 h -25.25252 -25.25253 v 10.10101 10.10101 h 10.10102 10.10099 v 5.681818 5.681819 H 858.5859 848.48488 v 10.101007 10.101015 h 25.25253 25.25252 v 10.101005 10.101012 h -35.35354 -35.35353 z m 80.80808,-40.40404 V 0 h 35.35356 35.35351 v 5.6818184 5.6818186 h 5.05047 5.05057 v 4.419191 4.419192 H 994.94953 1000 v 10.10101 10.10101 h -5.05047 -5.05048 v 5.681818 5.681819 h -5.05057 -5.05047 v 4.419189 4.419196 h 5.05047 5.05057 v 5.681819 5.681818 H 994.94953 1000 V 82.070704 92.171716 H 984.84848 969.69697 V 86.489898 80.80808 h -5.05048 -5.05047 V 70.707067 60.606062 h -10.10105 -10.10104 v 15.782824 15.78283 H 924.24246 909.09094 Z M 959.59602,30.30303 V 20.20202 h -10.10105 -10.10104 v 10.10101 10.10101 h 10.10104 10.10105 z"/>
  </svg>

  <h1>The server is having a lie-down.</h1>

  <p>tastehopping runs on one small computer, and that computer is switched off
  at the moment. This is not a fault — it is just not on.</p>

  <p>Nothing has been lost. Every account, every saved video and every vote is
  sitting on its disk exactly where it was, waiting for someone to press the
  power button.</p>

  <p>Try again in a while.</p>

  <p class="note">Served by <a href="https://github.com/manujarvinen/manuserver">manuserver</a>
  — a whole server on one machine, which is why it can be turned off.</p>
</main>
</body>
</html>`;
