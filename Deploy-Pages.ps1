# =====================================================================
#  Deploy-Pages.ps1 -- publishes the dashboard to Cloudflare Pages at
#  https://za-macro.pages.dev
#  (sarb.pages.dev and sarb-dashboard.pages.dev were both already taken
#  in Cloudflare's global *.pages.dev namespace -- shared across every
#  Cloudflare account, not just this one -- so za-macro was chosen instead.)
#
#  Stages just what the site needs (the HTML, the data sidecar, and the
#  _redirects rewrite) and pushes it with wrangler. Run it any time --
#  typically right after Update-SARB-Data.ps1 -- to put fresh archive
#  data on the web. Note the deployed page also live-refreshes the
#  fast-moving numbers from the SARB API by itself, so the site never
#  shows stale rates even if you don't redeploy for a while; redeploying
#  mainly refreshes the deep 1960s archives.
#
#  Needs: Node.js + a wrangler login (npx wrangler login) -- the same
#  setup already used for the SA CPI and Living Planet pages.
# =====================================================================
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $dir

$stage = Join-Path $dir ".deploy-stage"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $stage "data") | Out-Null
Copy-Item (Join-Path $dir "SARB_Dashboard.html") $stage
Copy-Item (Join-Path $dir "_redirects") $stage
Copy-Item (Join-Path $dir "data\live-data.js") (Join-Path $stage "data")

npx wrangler pages deploy $stage --project-name za-macro --branch main
Write-Host ""
Write-Host "Live at https://za-macro.pages.dev"
