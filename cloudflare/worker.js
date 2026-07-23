/**
 * SARB KBP catalogue updater Worker — a scheduled top-up job in front of the
 * SARB's "download facility" endpoint (custom.resbank.co.za/SarbWebApi has no
 * CORS problem and self-heals in-browser already; this endpoint is the one
 * that DOES have no CORS header, and is also the source of the ~2,320-code
 * Quarterly Bulletin catalogue that a plain client fetch() can never reach).
 *
 * What it does: on a schedule (Cron Trigger, every 15 min), checks a BOUNDED
 * chunk of already-held KBP codes for observations published since the last
 * time they were checked (a small ~15-month lookback per code, not a full
 * 1960-to-today re-fetch) and merges anything new onto the stored dataset in
 * KV. On request, serves that dataset (and a lightweight status/timestamp)
 * with permissive CORS headers so the deployed Pages site can pull a fresh
 * copy directly in-browser — the same self-heal pattern the rest of the app
 * already uses for the SARB's main API, just pointed at this Worker instead
 * of straight at an endpoint that would reject a browser's request outright.
 *
 * WHY CHUNKED (this is the part that isn't obvious from a first read):
 * Cloudflare Workers' free tier caps a single invocation at 50 outbound
 * subrequests. A full top-up cycle needs ~290 batches (2,318 codes at 8/
 * batch), so one invocation can only ever get through a fraction of it. A
 * `kbp_cursor` key in KV (`{freqIdx, codeIdx}`) tracks exactly where the last
 * invocation left off in the (frequency, code-offset) sequence; each run
 * does up to CHUNK_BATCHES batches from there and saves the cursor forward,
 * wrapping back to the start once every code has been checked. Firing every
 * 15 minutes, a full cycle through all ~2,320 codes takes a couple of hours —
 * actually MORE responsive than a single once-a-day run would have been, not
 * a compromise.
 *
 * Each code's `freq` field (the frequency string PROVEN to return data for
 * it, discovered the hard way via Update-SARB-Data.ps1's frequency-fallback
 * pass — the manifest's own Frequency column is wrong for a large share of
 * codes) is carried in the seeded dataset itself, so this Worker needs no
 * copy of kbp-manifest.json at all — every code in KV is self-describing.
 *
 * Routes:
 *   GET  /kbp-status   -> {updatedAt, count, lastRunNewCount, cyclePosition} of the cached dataset
 *   GET  /kbp-data      -> the full merged {code: {code,name,unit,obs,freq}} map
 *   POST /check-now     -> manually trigger one chunk, same as the cron
 *                          (protected by a shared secret, see wrangler.toml)
 *
 * Deploy: see ../cloudflare/README.md for the full walkthrough.
 */

const API = "https://www.resbank.co.za/bin/sarb/custom/downloadfacility";
const BATCH_SIZES = { "Monthly": 8, "Yearly": 8, "Daily (6 Days)": 2, "Weekly (5 days)": 2, "Quarterly": 5 };
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
// Stays under the free tier's 50-subrequest-per-invocation cap -- kept at 30,
// not close to 40, because KV get/put calls (up to ~6 per invocation: two
// reads at the top, up to three writes, one more read for meta) appear to
// count against the same budget, and a few "Too many subrequests" errors
// showed up in Cloudflare's dashboard at 40. That limit terminates the whole
// invocation rather than throwing a catchable error, so no try/catch in this
// file can handle it -- the only real fix is staying further back from it.
const CHUNK_BATCHES = 30;

function ymd(d) { return d.toISOString().slice(0, 10).replace(/-/g, "/"); }

// Period is an 8-digit YYYYMMDD integer with trailing components zero-padded
// (not omitted) for coarser frequencies -- a real day for Daily/Weekly codes,
// day=00 for Monthly, month=00+day=00 for Yearly. See Update-SARB-Data.ps1's
// Compact-KBP for the fuller writeup of why this matters (silently produced
// duplicated/invalid dates before this was understood).
function parsePeriod(periodRaw) {
  const s = String(periodRaw);
  if (s.length >= 8) {
    const yyyy = s.slice(0, 4), mm = s.slice(4, 6), dd = s.slice(6, 8);
    if (dd !== "00") return `${yyyy}-${mm}-${dd}`;
    if (mm !== "00") return `${yyyy}-${mm}`;
    return `${yyyy}-01`;
  }
  if (s.length >= 6) return `${s.slice(0, 4)}-${s.slice(4, 6)}`;
  return null;
}

function compactKBP(rows) {
  const byCode = {};
  for (const r of rows) {
    const code = r["TimeSeriesCode"];
    if (!code) continue;
    if (!byCode[code]) {
      const desc = String(r["LongDesc"] || "").replace(/<br\s*\/?>/gi, " -- ").replace(/\s+/g, " ").trim();
      byCode[code] = { code, name: desc, unit: r["UnitOfMeasure"], obs: [] };
    }
    const p = parsePeriod(r["Period"]);
    if (p == null) continue;
    const v = typeof r["Value"] === "number" ? r["Value"] : parseFloat(r["Value"]);
    if (!isNaN(v)) byCode[code].obs.push([p, v]);
  }
  return Object.values(byCode);
}

async function fetchBatch(codes, freqDesc, fromDate, toDate) {
  const url = `${API}?onlineDownload=sSRSData&sSRSDataTsCodes=${codes.join(",")}` +
    `&sSRSDataFrequencyDescription=${encodeURIComponent(freqDesc)}&sSRSDataStartDate=${fromDate}&sSRSDataEndDate=${toDate}`;
  const res = await fetch(url);
  const obj = await res.json();
  const tsObs = obj?.["xs:ssrsDataResult"]?.["diffgr:diffgram"]?.["TsObservations"];
  if (!tsObs) return []; // valid response, genuinely no data for this batch/window -- not an error
  const tbl = tsObs["Table"];
  return Array.isArray(tbl) ? tbl : [tbl];
}

function mergeSeries(kbp, series, freq) {
  let changed = 0;
  for (const s of series) {
    const existing = kbp[s.code];
    if (!existing) { kbp[s.code] = { ...s, freq }; changed++; continue; }
    const seen = new Set(existing.obs.map(o => o[0]));
    let added = 0;
    for (const o of s.obs) { if (!seen.has(o[0])) { existing.obs.push(o); seen.add(o[0]); added++; } }
    if (added > 0) {
      existing.obs.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);
      changed++;
    }
  }
  return changed;
}

// Processes up to CHUNK_BATCHES batches starting from the saved cursor
// position, across the (sorted, stable-order) list of frequency groups --
// resuming a partial cycle or starting a new one once the previous cycle
// finished. Cursor and data are saved incrementally so a mid-chunk failure
// never loses progress already made this invocation.
async function topUpChunk(env, log) {
  const kbp = (await env.SARB_KV.get("kbp_data", "json")) || {};
  const byFreq = {};
  for (const [code, s] of Object.entries(kbp)) {
    if (!s.freq) continue;
    (byFreq[s.freq] ||= []).push(code);
  }
  const freqList = Object.keys(byFreq).sort();
  const totalCodes = freqList.reduce((n, f) => n + byFreq[f].length, 0);

  let { freqIdx, codeIdx } = (await env.SARB_KV.get("kbp_cursor", "json")) || { freqIdx: 0, codeIdx: 0 };
  if (freqIdx >= freqList.length) { freqIdx = 0; codeIdx = 0; }

  const toDate = ymd(new Date());
  const from = new Date(); from.setMonth(from.getMonth() - 15);
  const fromDate = ymd(from);

  let batchesUsed = 0, totalNew = 0, kvDirty = false;
  while (batchesUsed < CHUNK_BATCHES && freqIdx < freqList.length) {
    const freq = freqList[freqIdx];
    const codes = byFreq[freq];
    const batchSize = BATCH_SIZES[freq] || 5;
    if (codeIdx >= codes.length) { freqIdx++; codeIdx = 0; continue; }
    const batch = codes.slice(codeIdx, codeIdx + batchSize);
    try {
      const rows = await fetchBatch(batch, freq, fromDate, toDate);
      const series = compactKBP(rows);
      const changed = mergeSeries(kbp, series, freq);
      if (changed > 0) { totalNew += changed; kvDirty = true; }
    } catch (e) {
      log(`batch failed (${batch.join(",")}): ${e.message}`);
    }
    codeIdx += batchSize;
    batchesUsed++;
    await new Promise(r => setTimeout(r, 250));
  }
  const wrapped = freqIdx >= freqList.length;
  if (wrapped) { freqIdx = 0; codeIdx = 0; }

  if (kvDirty) await env.SARB_KV.put("kbp_data", JSON.stringify(kbp));
  await env.SARB_KV.put("kbp_cursor", JSON.stringify({ freqIdx, codeIdx }));

  const checkedSoFar = freqList.slice(0, freqIdx).reduce((n, f) => n + byFreq[f].length, 0) + codeIdx;
  const meta = (await env.SARB_KV.get("kbp_meta", "json")) || {};
  await env.SARB_KV.put("kbp_meta", JSON.stringify({
    updatedAt: totalNew > 0 ? new Date().toISOString() : (meta.updatedAt || null),
    count: Object.keys(kbp).length,
    lastRunNewCount: totalNew,
    cyclePosition: `${checkedSoFar}/${totalCodes}`,
    lastCheckedAt: new Date().toISOString(),
  }));
  log(`chunk done: ${batchesUsed} batches, ${totalNew} code(s) changed, cycle at ${checkedSoFar}/${totalCodes}${wrapped ? " (cycle complete, wrapped)" : ""}`);
  return totalNew;
}

export default {
  async scheduled(event, env, ctx) {
    const lines = [];
    ctx.waitUntil(topUpChunk(env, t => lines.push(t)).catch(e => lines.push("ERROR: " + e.message)));
  },

  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { headers: CORS });

    if (url.pathname === "/kbp-status") {
      const meta = await env.SARB_KV.get("kbp_meta", "json");
      return Response.json(meta || { updatedAt: null, count: 0 }, { headers: CORS });
    }

    if (url.pathname === "/kbp-data") {
      const data = await env.SARB_KV.get("kbp_data");
      if (!data) return new Response("not seeded yet", { status: 404, headers: CORS });
      return new Response(data, { headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "public, max-age=3600" } });
    }

    if (url.pathname === "/check-now" && request.method === "POST") {
      // Manual trigger for testing -- requires the shared secret set in
      // wrangler.toml so this can't be used by a stranger to spam SARB's
      // server from your Worker. Runs exactly one chunk, same as the cron.
      const secret = request.headers.get("x-check-secret");
      if (!env.CHECK_SECRET || secret !== env.CHECK_SECRET) {
        return new Response("forbidden", { status: 403, headers: CORS });
      }
      const lines = [];
      const n = await topUpChunk(env, t => lines.push(t));
      return Response.json({ newCount: n, log: lines }, { headers: CORS });
    }

    return new Response(
      "SARB KBP updater Worker.\nRoutes: GET /kbp-status, GET /kbp-data, POST /check-now (needs x-check-secret header)",
      { headers: CORS }
    );
  },
};
