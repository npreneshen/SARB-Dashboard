# SARB Data Explorer

A single-file, HTML dashboard over the **South African Reserve Bank Web API** —
A modernisation of a personal Excel based dashboard.
Serves the complete public dataset. Companion to the SA CPI dashboard,
built on the same pattern: one HTML file, one PowerShell updater, one data sidecar.

**[Click here to try it in your browser →](https://za-macro.pages.dev)**
> Every chart has a table view, CSV and PNG export. Tables export to CSV and rows with a series code click through to a history pop-up
>  If you'd like to setup your own version see **[SETUP.md](SETUP.md)**
> Note: Intial load might take a few minutes if you've cloned the repo and are running it locally. Refresh the page once the powershell closes.


![Screenshot of Dashboard](screenshot.png)

```
SARB Dashboard/
├── SARB_Dashboard.html      the whole app (open it directly — file:// works)
├── Update-SARB-Data.ps1     pulls the SARB API into data/live-data.js
├── Open SARB Dashboard.bat  opens the app, then refreshes data in the background
├── Deploy-Pages.ps1         one-command publish to za-macro.pages.dev
├── _redirects               Pages rewrite (/ → /SARB_Dashboard)
└── data/
    └── live-data.js         ~6 MB offline archive (window.SARB_LIVE = {...})
```

## What's in it

| Tab | Contents |
|---|---|
| **Overview** | Repo / prime / CPI / PPI / rand tiles with sparklines, **interpolated government yield curve** (T-bill tenders + R2030/R209 + 5–10y/10y+ buckets; today vs 1w/1m/1y snapshots, instrument table in bps), overnight rates vs repo, live market-rates board, release register, desk notices |
| **Policy & Rates** | Repo & prime daily history, **real policy rate** (repo − CPI), the SARB's 60-year real prime series, NCD curve, CPD rates |
| **Rand & FX** | Majors since 1980 (log scale), NEER vs REER since 1970, 30-day realised volatility, bilateral-vs-basket divergence, full 33-pair FX board with rand-direction colouring |
| **Money & Credit** | M3 & private credit growth since 1966, aggregates since 1965, counterparts of M3 (12m flows), household-vs-corporate borrowing, credit by product, deposits by sector, securitisation |
| **Capital Markets** | Long-bond yield **since 1949**, daily benchmark yields, 10y−repo curve slope, JSE turnover, non-resident flows |
| **Government Finance** | Revenue vs expenditure (12m rolling), the deficit with seasonality stripped, financing mix, debt ratios |
| **External & Gold** | Reserves & liquidity position, import cover, current account, forex-market turnover by instrument, gold in rand vs dollar since 1960 |
| **Real Economy** | Business-cycle indicators since 1960, production **since 1946** (gold mining), sales momentum, GDP growth, CPI/PPI pipeline vs target band, all six IMF SDDS tables |
| **Market Operations** | Repo auctions, T-bill tenders, valuation rates, special announcements — parsed from the desk's own notices (23 categories) |
| **Explorer** | Every held series (~250) searchable with hover descriptions, unlimited overlays, Level / YoY / MoM / 12-m-sum / Index transforms, FRED-style series arithmetic (A−B, A÷B×100, …), per-series axis placement, and a box to live-fetch **any** SARB timeseries code (the KBP Quarterly Bulletin universe included) |

 

## How data flows

1. **`data/live-data.js`** — written by `Update-SARB-Data.ps1`. Full offline archive:
   twelve statistical releases back to 1946–1965, 60+ deep daily/monthly series, SDDS
   tables, MCM notices. Loaded as a plain `<script src>`, so it works from `file://`.
2. **Live API calls** — unlike StatsSA, the SARB API sends
   `Access-Control-Allow-Origin: *`, so the page refreshes the fast-moving numbers
   (rates boards, FX, tails of daily series) straight from the browser, even opened
   from disk. The badge (top-right) shows which mode you're in. With no sidecar at
   all, the page still boots entirely from the API, fetching archives on demand
   per tab.

## The updater

```powershell
.\Update-SARB-Data.ps1              # incremental (seconds — only re-pulls what changed)
.\Update-SARB-Data.ps1 -Force       # full re-download (~40 MB raw, a few minutes)
.\Update-SARB-Data.ps1 -Install     # daily 18:30 scheduled task
.\Update-SARB-Data.ps1 -Uninstall   # remove the task
```


## SARB Web API endpoints used

Base: `https://custom.resbank.co.za/SarbWebApi`

| Endpoint | Data |
|---|---|
| `WebIndicators/HomePageRates` | headline rates board |
| `WebIndicators/CurrentMarketRates` | full market rates board |
| `WebIndicators/CPDRates` | Corporation for Public Deposits |
| `WebIndicators/HistoricalExchangeRatesDaily` / `Monthly` | FX boards (33 pairs, NEER/REER) |
| `WebIndicators/OtherIndicators` (+`/HistoricalDatesOfRateChanges`) | headline ratios, last repo/prime changes |
| `WebIndicators/ReleaseOfSelectedData` | release register |
| `WebIndicators/ReleaseOfSelectedData/MonthlyIndicatorsAll/{type}` | 12 archives: MRDMA, MRDBM, MRDIE, MRDFG, MRDCM, MRDEI, CDACSQ, CDACSM, CDASA, CDADS, CDACA, CDACM3 |
| `WebIndicators/ReleaseOfSelectedData/{Group}Graphs/{n}` | SARB's curated chart series |
| `WebIndicators/Shared/GetTimeseriesObservations/{code}/{from}/{to}` | deep history for **any** series code |
| `WebIndicators/EconFinDataForSA/Get{Real,Financial,External,Fiscal,Population}SectorData` | IMF SDDS tables |
| `MCM/Categories` + `MCM/Contributions/{id}` | money-market desk notices (XML payloads, parsed in-page) |


## Cloudflare Pages hosting

The site at **https://za-macro.pages.dev** is plain static hosting on Cloudflare's
**free tier** —
(Pages free tier: unlimited bandwidth, 500 deploys/month). Unlike StatsSA (which forced the
CPI dashboard to run a Worker relay), the SARB API sends `Access-Control-Allow-Origin: *`,
so the deployed page refreshes everything straight from the visitor's browser. The page also
**self-heals stale archives**: on load it compares the SARB's release register against what
the bundled sidecar holds and silently re-fetches anything the SARB has republished since
the last deploy. To push a fresh archive baseline after running the updater:

```powershell
.\Deploy-Pages.ps1     # stages HTML + data + _redirects, runs wrangler pages deploy
```

If the sidecar on the site ever grows stale, nothing visibly breaks — the page's live
layer keeps the rates, FX board and SDDS tables current on its own.

**The exact commands used to stand this up** (for reference — `Deploy-Pages.ps1` already
wraps steps 3–4 for every deploy after the first):

```powershell
npx wrangler login                                              # one-time browser auth
npx wrangler pages project create za-macro --production-branch main   # one-time project creation
npx wrangler pages deploy .deploy-stage --project-name za-macro --branch main  # each deploy
npx wrangler pages project list                                 # list your projects/URLs
```



Data © South African Reserve Bank. This is an independent viewer, not affiliated
with or endorsed by the SARB.
