# Cloudflare Worker + Pages setup (optional)

**This entire folder is optional.** The app works completely on its own with
`Update-SARB-Data.ps1` run locally (manually, or via `-Install`'s scheduled task) — nothing
here is required. This is for if you'd rather have the ~2,320-code KBP catalogue stay current
automatically in the cloud, with no PC involved at all.

## Is this worth doing?

Read this before spending the ~20 minutes it takes to set up.

- **The SARB's *main* API needs no Worker at all.** `custom.resbank.co.za/SarbWebApi` sends
  `Access-Control-Allow-Origin: *`, so the deployed app already self-heals the 12 core
  statistical archives, live rates, and desk notices straight from the browser, on every page
  load, with zero server involved. This Worker exists for exactly one thing: the separate
  "download facility" endpoint (`resbank.co.za/bin/sarb/custom/downloadfacility`), which serves
  the KBP catalogue and sends **no** CORS header at all — a browser can never reach it directly,
  Worker or not.
- **`Update-SARB-Data.ps1` already works reliably** and needs nothing but a Windows PC that's
  occasionally on. If that's fine for you, you don't need any of this.
- Where this genuinely helps: you want visitors to always see a current KBP catalogue even if
  your own PC hasn't been on in weeks, and/or you want the site itself hosted independently of
  your machine.
- **Confirmed working, not theoretical**: this was built and tested live — a manual
  `/check-now` trigger against the real download-facility endpoint successfully fetched and
  merged real data, and the deployed app's live client-side check against the Worker's
  `/kbp-status` endpoint was verified end-to-end (comparison logic, stamp handling, full
  dataset fetch-and-merge — all confirmed working, not just written and assumed correct).

If you never set this up, nothing is lost — the deployed Pages site still works exactly like a
plain local file does, and `KBP_WORKER_URL` just needs to be emptied out (or left as-is if you
never got your own Worker running — a 404/network error from a nonexistent URL is caught the
same as any other unreachable network call and just means no live top-up happens, same as
before this feature existed).

---

## Quick start

1. **Install Node.js** if you don't have it (it's only needed for the `wrangler` CLI tool, not
   for the app itself): https://nodejs.org — get the LTS version.
2. **Create a free Cloudflare account** at https://dash.cloudflare.com/sign-up if you don't
   have one.
3. Open a terminal **in this `cloudflare` folder**:
   ```powershell
   cd "C:\Users\P\Downloads\SARB Dashboard\cloudflare"
   npx wrangler login
   ```
   This opens a browser tab to authorize the CLI against your Cloudflare account.
4. **Create the KV namespace** the Worker uses to store the dataset:
   ```powershell
   npx wrangler kv namespace create SARB_KV
   ```
   It prints something like:
   ```
   [[kv_namespaces]]
   binding = "SARB_KV"
   id = "a1b2c3d4e5f6..."
   ```
   Copy that `id` value into `wrangler.toml` in this folder, replacing the existing id.
5. **Set a secret** (protects the manual-trigger endpoint from strangers — pick any random
   string, or generate one: `python -c "import secrets; print(secrets.token_urlsafe(24))"`):
   ```powershell
   npx wrangler secret put CHECK_SECRET
   ```
   It'll prompt you to paste a value. Save it somewhere (a password manager is fine) — you'll
   use it below to test the Worker.
6. **Seed the KV store** with your current local data, so the Worker has something to top up
   rather than starting from nothing (it does NOT re-fetch full history itself — see
   "Architecture" below for why):
   ```powershell
   cd "C:\Users\P\Downloads\SARB Dashboard"
   python -c "import json; d=json.load(open('data/live-data.js').read()[open('data/live-data.js').read().index('=')+1:].strip().rstrip(';')); open('cloudflare/kbp-seed.json','w').write(json.dumps(d['kbp']))"
   cd cloudflare
   npx wrangler kv key put "kbp_data" --path kbp-seed.json --namespace-id <your-namespace-id> --remote
   ```
   (The one-liner above is a simplified version of what actually generated the seed file this
   project used — if it errors on your exact `live-data.js` shape, just ask Claude to extract
   the `kbp` field into a standalone JSON file, then run the `wrangler kv key put` line.)
7. **Deploy the Worker**:
   ```powershell
   npx wrangler deploy
   ```
   It prints a URL like `https://sarb-kbp-updater.<your-subdomain>.workers.dev` — that's your
   `KBP_WORKER_URL`.
8. **Test it manually** (don't wait for the next scheduled run):
   ```powershell
   curl -X POST https://sarb-kbp-updater.<your-subdomain>.workers.dev/check-now -H "x-check-secret: <secret>"
   ```
   Returns JSON with a `log` array showing which codes it checked and a `cyclePosition` showing
   progress through the full catalogue. Then check:
   ```powershell
   curl https://sarb-kbp-updater.<your-subdomain>.workers.dev/kbp-status
   ```
   should show `{"updatedAt":"...","count":2318,"lastRunNewCount":0,"cyclePosition":"40/2318",...}`
   (a `lastRunNewCount` of 0 is normal and expected most runs — it just means nothing newer was
   published for that particular chunk of codes since last time).
9. **Point the app at your Worker.** Edit the app's source (or ask Claude to) — the line near
   the top of `part2.js` in the source scratchpad:
   ```js
   const KBP_WORKER_URL = "https://sarb-kbp-updater.n-preneshen.workers.dev";
   ```
   change to your own Worker's URL, then rebuild the combined `SARB_Dashboard.html`.
10. **Deploy the app itself** with `Deploy-Pages.ps1` as usual.
11. **Verify end to end**: open the deployed site, and in the browser console check
    `D.kbpStamp` — it should match (or be older than) your Worker's `updatedAt`. The check runs
    automatically on every page load, no button to click.

That's it. The Worker's cron trigger (every 15 minutes, see `wrangler.toml`) keeps working
through the catalogue on its own from here on — no PC needs to be running.

---

## Architecture, for anyone setting this up on their own copy of the project

```
                    ┌──────────────────────┐
 cron (every 15 min) │                      │
   ───────────────► │   Cloudflare Worker   │──── GET (small batches) ───► SARB download facility
                     │   (sarb-kbp-updater)  │                             (no CORS, server-only)
                     └──────────┬───────────┘
                                 │ merged {code: {obs, freq, ...}}
                                 ▼
                     ┌──────────────────────┐
                     │   Workers KV (store)  │
                     └──────────┬───────────┘
                                 │ GET /kbp-data, GET /kbp-status
                                 ▼
        ┌─────────────────────────────────────────────┐
        │   SARB_Dashboard.html (on Cloudflare Pages)   │
        │   — compares its own baked-in kbpStamp vs      │
        │   the Worker's updatedAt; only pulls the full  │
        │   dataset when the Worker is genuinely ahead   │
        └─────────────────────────────────────────────┘
```

**Why the Worker only tops up, and never re-fetches full history**: unlike a code's history
(which barely ever changes once published), a code's *newest* observation changes constantly —
that's the only part worth checking on a schedule. The Worker's `kbp_data` KV value is seeded
once from your local `Update-SARB-Data.ps1` output (which already did the expensive one-time
work of discovering each code's correct frequency and full history), and every scheduled run
just asks "anything published in roughly the last 15 months that I don't already have?" for
each code — a small, cheap, per-code request rather than a full re-fetch of thousands of
codes' entire histories.

**Why it's chunked across many small runs instead of one big one**: Cloudflare Workers' free
tier caps a single invocation at 50 outbound subrequests (`fetch()` calls to other servers) —
comfortably enough for the ~11-code-per-request cap the SARB's own WAF enforces on this
endpoint, but nowhere near enough to check all ~2,320 codes (needs ~290 batches) in one go. A
`kbp_cursor` KV key remembers exactly where the last run left off (which frequency group, which
offset within it) and each run processes up to `CHUNK_BATCHES` batches from there, wrapping
back to the start once every code has been checked. At every 15 minutes, a full cycle through
the whole catalogue still takes only a few hours — genuinely more responsive than a single
once-a-day run would have been, not a workaround forced by the limit.

`CHUNK_BATCHES` was initially set to 40 and showed occasional "Too many subrequests" errors in
Cloudflare's dashboard in practice — KV reads/writes (up to ~6 per invocation) appear to count
against the same 50-subrequest budget as the SARB fetch() calls, so 40 batches + 6 KV ops left
too little headroom. Lowered to **30** for a safer margin. That limit terminates the whole
invocation rather than throwing a catchable JS error, so no amount of try/catch fixes it —
only staying further back from the cap does.

**Why each code carries its own `freq` field**: the manifest's own Frequency column (from the
SARB's published Excel) turned out to be wrong for a large share of codes — e.g. a code tagged
"Quarterly" that only actually returns data when queried as "Yearly". `Update-SARB-Data.ps1`
discovered the *proven-correct* frequency for every code the hard way (a bounded fallback-retry
pass), and that's what gets seeded into KV — so the Worker never needs to guess, retry, or even
know about `kbp-manifest.json` at all. It just trusts what's already recorded per code.

### Files in this folder

| File | Purpose |
|---|---|
| `worker.js` | The Worker itself — a scheduled chunked top-up job plus 3 HTTP routes (`/kbp-status`, `/kbp-data`, `/check-now`). |
| `wrangler.toml` | Worker configuration: cron schedule, KV namespace binding. Edit the KV `id` after step 4 above. |
| `README.md` | This file. |

### Endpoints

| Route | Method | Auth | Purpose |
|---|---|---|---|
| `/kbp-status` | GET | none | `{updatedAt, count, lastRunNewCount, cyclePosition, lastCheckedAt}` |
| `/kbp-data` | GET | none | The full merged `{code: {code, name, unit, obs, freq}}` map (a few MB) |
| `/check-now` | POST | `x-check-secret` header | Manually run one chunk, same as the cron |

The `GET` routes are intentionally open (no auth) — they only ever serve the SARB's own public
data, so there's nothing to protect. `/check-now` is gated because without a secret, anyone who
found your Worker's URL could trigger repeated outbound requests to SARB from your account,
which is the one thing worth guarding against.

### Free-tier limits (as of when this was written — check Cloudflare's current pricing page,
these change)

- **Workers**: 100,000 requests/day, **50 subrequests per invocation** (this is the one that
  actually shapes this design — see "chunked" above, and note KV operations count against it
  too, not just `fetch()` calls). The cron fires 96 times/day; each is one request with up to
  ~36 total subrequests (30 SARB batches + ~6 KV ops), safely under both caps.
- **Workers KV**: 100,000 reads/day, 1,000 writes/day, 1 GB total storage, 25 MB per value. This
  project's dataset is currently ~8-14 MB (comfortably under the per-value cap) and writes to
  KV at most a few times per chunk run — nowhere close to the daily write cap even at 96
  runs/day.
- **Cron Triggers**: this project uses one (`*/15 * * * *`).
- **Pages**: 500 builds/month, unlimited requests/bandwidth on the free plan.

### Troubleshooting

- **`/check-now` log is full of "batch failed" messages**: the SARB's download-facility
  endpoint has shown genuine intermittent server-side instability (confirmed via direct curl
  testing outside any of this project's code) — a run with some failures isn't a bug, the
  chunk's cursor still advances and gets retried on the next cycle. If EVERY batch in a chunk
  fails, check the SARB's site is up at all first.
- **`/kbp-status` shows `count` growing past 2,320 or `lastRunNewCount` unexpectedly huge**:
  something's off with the seed data or the manifest — check the seed step was done correctly.
- **App doesn't seem to be checking the Worker at all**: confirm `KBP_WORKER_URL` is actually
  set in the built `SARB_Dashboard.html` (search the file for your Worker's URL). Also check the
  browser's Network tab for requests to your Worker's `/kbp-status` endpoint on page load — a
  CORS error there means the Worker didn't deploy correctly (`npx wrangler deploy` again).
- **`wrangler` commands fail with an auth error**: run `npx wrangler login` again — the token
  can expire.
