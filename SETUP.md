# Setting up the SARB Data Explorer — a first-time guide

This guide assumes **no prior knowledge**. It explains what this project is, the three ways
to use it, and exactly how to set each one up — including hosting your own copy on the web
for free.

---

## What is this?

A dashboard for South African Reserve Bank data: interest rates, the rand, money and credit,
government finance, bond yields and more — some series going back to 1946. It is built as
**one HTML file** that reads data from two places:

1. **The SARB's own public API** (`custom.resbank.co.za/SarbWebApi`) — fetched live by your
   browser whenever you're online. The SARB allows this from any website or local file, no
   key or account needed.
2. **A local data file** (`data/live-data.js`, ~6 MB) — the full historical archive, written
   by the included PowerShell script. This is what makes the deep 1946–2026 history load
   instantly and lets the whole thing work offline.

There is **no database, no server and no login** anywhere in this project.

---

## Option 1 — just visit the website (nothing to install)

**https://za-macro.pages.dev**

That's the finished product, hosted on Cloudflare Pages. It refreshes live rates itself in
your browser. You only need the rest of this guide if you want your own local or hosted copy.

---

## Option 2 — run it on your own PC (Windows)

1. **Get the folder.** Copy the whole `SARB Dashboard` folder anywhere on your PC
   (or download it from the GitHub repository if one has been set up). It must keep its
   structure: the `.html`, the `.ps1` scripts and the `data\` folder side by side.
2. **Open it.** Double-click **`Open SARB Dashboard.bat`**. It opens the dashboard in your
   default browser immediately, and quietly refreshes the data archive in the background
   for next time. (You can also just double-click `SARB_Dashboard.html` directly.)
3. **First run notes:**
   - If Windows SmartScreen warns about the `.bat` or `.ps1`, that's because they're
     unsigned scripts from outside the Store. "More info → Run anyway" is safe — the scripts
     only talk to `resbank.co.za` and write files inside this folder. You can read them;
     they're plain text.
   - If the data folder is empty and you're **online**, the page still works — it fetches
     everything from the SARB API on the fly (the big archives load per tab, a few seconds
     each). Running the updater once makes all of that instant and available offline.
4. **Keep it fresh automatically (optional).** In PowerShell, from this folder:
   ```powershell
   .\Update-SARB-Data.ps1 -Install
   ```
   That registers a Windows scheduled task, daily at 18:30, that tops up the archive
   incrementally (takes well under a minute; only re-downloads what the SARB has actually
   republished). `-Uninstall` removes it. `-Force` rebuilds the whole archive from scratch
   (~40 MB download, a few minutes) — only needed if the data file is deleted or corrupted.

---

## Option 3 — host your own copy on the web (free, ~15 minutes)

This puts the dashboard on a public `*.pages.dev` address using Cloudflare Pages' free tier,
exactly like za-macro.pages.dev. Useful if you want to share your own link or customise
the page.

**Do you need a "Worker"?** For the site itself, no. The SARB's main API sends the CORS
header (`Access-Control-Allow-Origin: *`) that tells browsers "anyone may read this", so
the 12 core archives, live rates, FX board and desk notices are pure static hosting — no
Worker, no cron trigger, no KV storage, no secrets. There's exactly **one** optional
exception: the ~2,320-code KBP catalogue lives behind a separate SARB endpoint with no
CORS support at all, so keeping *that* current without ever touching your own PC needs a
small (free-tier) Cloudflare Worker — see **[cloudflare/README.md](cloudflare/README.md)**
if you want that. It's entirely optional; without it, the KBP catalogue just stays as
current as whenever you last ran `Update-SARB-Data.ps1` and redeployed.

Steps:

1. **Install Node.js** (needed only for Cloudflare's `wrangler` command-line tool):
   https://nodejs.org — download the LTS version, run the installer, accept defaults.
2. **Create a free Cloudflare account**: https://dash.cloudflare.com/sign-up
   (email + password; no card needed for Pages' free tier).
3. **Log the tool into your account.** Open PowerShell in this folder and run:
   ```powershell
   npx wrangler login
   ```
   A browser tab opens asking you to authorise — click Allow. (`npx` downloads and runs
   wrangler on demand; the first run takes a minute.)
4. **Create the Pages project** (one time; pick your own name — it becomes the URL). Note
   the `*.pages.dev` namespace is **global across every Cloudflare account**, not just
   yours, so an obvious name may already be taken — Cloudflare silently appends a random
   suffix (e.g. `my-dashboard-9ne.pages.dev`) if it is:
   ```powershell
   npx wrangler pages project create my-sarb-dashboard --production-branch main
   ```
   The command's output tells you the actual URL you got — check it before moving on.
5. **Deploy.** Edit `Deploy-Pages.ps1` and change the project name (it appears twice: once
   in the `wrangler pages deploy` line, once in the final "Live at" message) to match what
   you created in step 4. Then:
   ```powershell
   .\Deploy-Pages.ps1
   ```
   It stages the three things the site needs — `SARB_Dashboard.html`, `data/live-data.js`
   and `_redirects` (a one-line rule that makes the bare URL serve the dashboard) — and
   uploads them. The site is live within a minute at the URL from step 4.
6. **Updating the site later.** Run `Update-SARB-Data.ps1` (fresh archive), then
   `Deploy-Pages.ps1` (push it). Even if you never redeploy, the site stays current: the
   live API layer updates rates in each visitor's browser, and the page checks the SARB's
   release register on load — if the SARB has published newer statistics than the bundled
   archive holds, it re-fetches those datasets live automatically.

**Costs and limits:** Cloudflare Pages' free tier allows 500 deployments/month and unlimited
bandwidth — this project uses a fraction of a fraction of that. The SARB API is public and
unauthenticated; the dashboard's polite about it (one burst of small requests per visit).

---

## What each file does

| File | Role |
|---|---|
| `SARB_Dashboard.html` | The entire application — open in any modern browser |
| `data/live-data.js` | Generated data archive (`window.SARB_LIVE = {…}`); safe to delete, regenerate with the updater |
| `Update-SARB-Data.ps1` | Pulls the SARB API into the archive; `-Force` / `-Install` / `-Uninstall` / `-Quiet` |
| `Open SARB Dashboard.bat` | Double-click convenience: open the app + background refresh |
| `Deploy-Pages.ps1` | Publish to your Cloudflare Pages project |
| `_redirects` | Cloudflare rule so `/` serves the dashboard |
| `README.md` | Technical documentation (API endpoints, architecture, gotchas) |
| `cloudflare/` | Optional Worker that keeps the KBP catalogue current without your PC — see its own README |

## Troubleshooting

- **"running scripts is disabled on this system"** — PowerShell's execution policy. The
  `.bat` already bypasses it; if running the `.ps1` directly, use:
  `powershell -ExecutionPolicy Bypass -File .\Update-SARB-Data.ps1`
- **Charts empty and badge says offline** — you have no `data/live-data.js` *and* no
  internet. Run the updater once while online.
- **Updater errors on some series** — normal if the SARB API hiccups; it keeps the previous
  data for anything that fails and heals on the next run.
- **`npx wrangler` not recognised** — Node.js isn't installed or the terminal was open
  before installing; open a new PowerShell window.
