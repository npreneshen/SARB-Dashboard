# =====================================================================
#  Update-SARB-Data.ps1  -  pulls the South African Reserve Bank Web API
#  (https://custom.resbank.co.za/SarbWebApi) and writes data/live-data.js
#  so SARB_Dashboard.html can load it even when opened as a plain
#  double-clicked file (file://), no local server required.
#
#  Unlike StatsSA, the SARB API sends Access-Control-Allow-Origin: *,
#  so the dashboard also refreshes itself live in the browser when
#  online. This script exists for (a) the deep offline archive -- the
#  1960-onward statistical releases are ~40 MB raw and far too slow to
#  pull on every page load -- and (b) fully offline use.
#
#  Runs are incremental: the big statistical-release datasets are only
#  re-downloaded when the SARB's own release register shows a newer
#  LastPeriod than what we already hold; daily series are fetched from
#  their last stored date forward and merged. A first/-Force run pulls
#  everything (~40 MB, a few minutes).
#
#  Usage:
#    .\Update-SARB-Data.ps1              incremental update
#    .\Update-SARB-Data.ps1 -Force       full re-download of everything
#    .\Update-SARB-Data.ps1 -Install    register a daily 18:30 scheduled task
#    .\Update-SARB-Data.ps1 -Uninstall  remove that scheduled task
# =====================================================================
param([switch]$Force, [switch]$Install, [switch]$Uninstall, [switch]$Quiet)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $dir "data"
$liveDataPath = Join-Path $dataDir "live-data.js"
$taskName = "SARB Dashboard Data Update"
$base = "https://custom.resbank.co.za/SarbWebApi"

function Say($msg) { if (-not $Quiet) { Write-Host $msg } }

if ($Install) {
    $act = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Quiet"
    $trig = New-ScheduledTaskTrigger -Daily -At 18:30
    Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trig -Force | Out-Null
    Say "Scheduled task '$taskName' registered (daily 18:30 -- after SARB's afternoon rate publications)."
    return
}
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Say "Scheduled task removed."
    return
}

# ---------------------------------------------------------------------
#  JSON via .NET JavaScriptSerializer: ConvertFrom-Json in PS 5.1 takes
#  minutes on the 11 MB money-and-banking payload; the serializer does
#  it in seconds and its Dictionary output is faster to walk too.
# ---------------------------------------------------------------------
Add-Type -AssemblyName System.Web.Extensions
$Ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Ser.MaxJsonLength = [int]::MaxValue
$Ser.RecursionLimit = 1000

$Inv = [System.Globalization.CultureInfo]::InvariantCulture
$NumStyle = [System.Globalization.NumberStyles]::Float
# The release archives serve VALUES AS SOUTH AFRICAN LOCALE STRINGS:
# comma is the DECIMAL separator ("361,9" = 361.9) and non-breaking
# space U+00A0 is the THOUSANDS separator ("1 571" = 1571). Strip the
# spaces, turn the comma into a period, then parse invariant. Plain
# JSON numbers (the rates endpoints) take the fast path.
function ToF($x) {
    if ($null -eq $x -or "$x" -eq "") { return $null }
    if ($x -is [double] -or $x -is [decimal] -or $x -is [int] -or $x -is [long]) { return [math]::Round([double]$x, 4) }
    $s = ([string]$x) -replace "[\u00A0\u202F\u2009\u0020]", ""
    $s = $s.Replace(",", ".")
    $f = 0.0
    if ([double]::TryParse($s, $NumStyle, $Inv, [ref]$f)) { return [math]::Round($f, 4) }
    return $null
}
# Periods arrive as "2026-07-20T00:00:00" or "1960/01/31 00:00:00"; keep
# "YYYY-MM-DD" for daily data and "YYYY-MM" for monthly/quarterly.
function PDay($p) {
    $s = [string]$p
    if ($s -match '^(\d{4})[-/](\d{2})[-/](\d{2})') { return "$($Matches[1])-$($Matches[2])-$($Matches[3])" }
    return $null
}
function PMon($p) {
    $s = [string]$p
    if ($s -match '^(\d{4})[-/](\d{2})') { return "$($Matches[1])-$($Matches[2])" }
    return $null
}

function FetchRaw($url) {
    $tries = 0
    while ($true) {
        $tries++
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 180
            return $resp.Content
        } catch {
            if ($tries -ge 3) { throw }
            Start-Sleep -Seconds (3 * $tries)
        }
    }
}
function FetchJson($url) { return $Ser.DeserializeObject((FetchRaw $url)) }

# ---------------------------------------------------------------------
#  Compactors. The API repeats name/description/format on every single
#  observation; we keep one metadata record per series and store
#  observations as bare [period, value] pairs sorted ascending.
#
#  Sorting must NOT go through Sort-Object: the pipeline wraps each
#  element in a PSObject, and JavaScriptSerializer then reflects into
#  PSObject internals and dies on a circular reference. List.Sort with
#  a comparison delegate keeps elements as the plain arrays we added.
# ---------------------------------------------------------------------
function SortObs([System.Collections.Generic.List[object]]$list) {
    $list.Sort([Comparison[object]]{ param($a, $b) [string]::CompareOrdinal([string]$a[0], [string]$b[0]) })
    return ,$list.ToArray()
}

# Rows of a statistical release (MonthlyIndicatorsAll) -> array of series.
function Compact-Release($rows) {
    $byKey = [ordered]@{}
    foreach ($r in $rows) {
        $code = [string]$r["TimeSeriesCode"]
        if (-not $code) { continue }
        $cat = [string]$r["CategoryCode"]
        $key = "$cat|$code"
        if (-not $byKey.Contains($key)) {
            $desc = ([string]$r["Description"]) -replace '<br\s*/?>', ' -- ' -replace '\s+', ' '
            $byKey[$key] = @{
                code = $code; cat = $cat; catName = [string]$r["CategoryName"]
                name = ([string]$r["MeasureName"]).Trim(); sub = [string]$r["SubTitle"]
                desc = $desc.Trim(); fmt = [string]$r["FormatNumber"]; fmtDate = [string]$r["FormatDate"]
                obs = New-Object System.Collections.Generic.List[object]
            }
        }
        $p = PMon $r["Period"]; $v = ToF $r["Value"]
        if ($p -and $null -ne $v) { $byKey[$key].obs.Add(@($p, $v)) }
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in $byKey.Keys) {
        $s = $byKey[$k]
        $s.obs = SortObs $s.obs
        $out.Add($s)
    }
    return ,$out.ToArray()
}

# GetTimeseriesObservations rows -> {name, desc, fmt, obs:[[date,val]]}.
function Compact-Obs($rows, $daily) {
    if ($null -eq $rows) { return $null }
    if ($rows -is [System.Collections.IDictionary]) { $rows = @(,$rows) }
    if ($rows.Count -eq 0) { return $null }
    $first = $rows[0]
    if ($null -eq $first) { return $null }
    $obs = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($r in $rows) {
        if ($daily) { $p = PDay $r["Period"] } else { $p = PMon $r["Period"] }
        $v = ToF $r["Value"]
        if ($p -and $null -ne $v -and -not $seen.Contains($p)) { $obs.Add(@($p, $v)); $seen[$p] = $true }
    }
    $sorted = SortObs $obs
    $desc = (([string]$first["Description"]) -replace '<br\s*/?>', ' -- ' -replace '\s+', ' ').Trim()
    return @{ name = [string]$first["Timeseries"]; desc = $desc; fmt = [string]$first["FormatNumber"]; obs = $sorted }
}

# Graph rows -> series array (same idea, keyed by TimeseriesCode).
function Compact-Graph($rows) {
    $byKey = [ordered]@{}
    foreach ($r in $rows) {
        $code = [string]$r["TimeseriesCode"]
        if (-not $code) { continue }
        if (-not $byKey.Contains($code)) {
            $byKey[$code] = @{
                code = $code; name = [string]$r["Name"]
                desc = (([string]$r["Description"]) -replace '<br\s*/?>', ' -- ' -replace '\s+', ' ').Trim()
                fmt = [string]$r["FormatNumber"]; seq = [int](ToF $r["Sequence"])
                obs = New-Object System.Collections.Generic.List[object]
            }
        }
        $p = PMon $r["Period"]; $v = ToF $r["Value"]
        if ($p -and $null -ne $v) { $byKey[$code].obs.Add(@($p, $v)) }
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in $byKey.Keys) {
        $s = $byKey[$k]; $s.obs = SortObs $s.obs; $out.Add($s)
    }
    return ,$out.ToArray()
}

# Snapshot rows (HomePageRates and friends) -> trimmed field set.
function Compact-Snapshot($rows) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        $out.Add(@{
            name = [string]$r["Name"]; section = [string]$r["SectionName"]; sectionId = [string]$r["SectionId"]
            code = [string]$r["TimeseriesCode"]; date = [string]$r["Date"]; value = ToF $r["Value"]
            upDown = [int](ToF $r["UpDown"]); fmt = [string]$r["FormatNumber"]; fmtDate = [string]$r["FormatDate"]
        })
    }
    return ,$out.ToArray()
}

# OtherIndicators / EconFinDataForSA / HistoricalDatesOfRateChanges share
# the Ts/Measure/TheValue shape.
# The EconFinDataForSA (SDDS) endpoints return TWO rows per indicator code
# -- the prior period and the latest -- presumably so the SARB's own site
# can show a period-over-period change. We only ever want one row per
# code; the API's own PercChange field is usually blank anyway, so we
# compute the change ourselves from the two periods before collapsing to
# just the latest one.
function Compact-Measures($rows) {
    $byCode = [ordered]@{}
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($r in $rows) {
        $d = ""
        if ($r.ContainsKey("Description")) { $d = (([string]$r["Description"]) -replace '<br\s*/?>', ' -- ' -replace '\s+', ' ').Trim() }
        $rec = @{
            section = [string]$r["SectionName"]; sectionId = [string]$r["SectionId"]
            code = [string]$r["TsCode"]; name = ([string]$r["MeasureName"]).Trim()
            value = ToF $r["TheValue"]; date = PDay $r["ValueDate"]; desc = $d
            fmt = [string]$r["FormatNumber"]; fmtDate = [string]$r["FormatDate"]
        }
        if ($r.ContainsKey("UnitOfMeasure")) { $rec.unit = ([string]$r["UnitOfMeasure"]).Trim() }
        if ($r.ContainsKey("PercChange")) { $rec.chg = ToF $r["PercChange"] }
        if ($r.ContainsKey("SectionSequence")) { $rec.secSeq = [int](ToF $r["SectionSequence"]) }
        if ($r.ContainsKey("ItemSequence")) { $rec.itemSeq = [int](ToF $r["ItemSequence"]) }
        $key = "$($rec.section)|$($rec.code)|$($rec.name)"
        if (-not $byCode.Contains($key)) { $byCode[$key] = New-Object System.Collections.Generic.List[object]; $order.Add($key) }
        $byCode[$key].Add($rec)
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($key in $order) {
        # NB: never `| Sort-Object` here -- piping Hashtables through it
        # wraps each in a PSObject, which breaks bracket indexing ($x["k"])
        # and JavaScriptSerializer downstream (same trap as SortObs above).
        # List.Sort with a comparison delegate keeps these plain Hashtables.
        $group = $byCode[$key]
        $group.Sort([Comparison[object]]{ param($a, $b) [string]::CompareOrdinal([string]$a.date, [string]$b.date) })
        $latest = $group[$group.Count - 1]
        if ($group.Count -gt 1 -and -not $latest.chg) {
            $prev = $group[$group.Count - 2]
            if ($null -ne $prev.value -and $prev.value -ne 0 -and $null -ne $latest.value) {
                $latest.chg = [math]::Round((($latest.value / $prev.value) - 1) * 100, 4)
            }
        }
        $out.Add($latest)
    }
    return ,$out.ToArray()
}

# ---------------------------------------------------------------------
#  Load existing sidecar for incremental updates / last-known-good.
# ---------------------------------------------------------------------
New-Item -ItemType Directory -Force $dataDir | Out-Null
$existing = $null
if ((Test-Path $liveDataPath) -and -not $Force) {
    try {
        $txt = [IO.File]::ReadAllText($liveDataPath)
        $jsonPart = ($txt -replace '^window\.SARB_LIVE = ', '') -replace ';\s*$', ''
        $existing = $Ser.DeserializeObject($jsonPart)
        Say "Existing data loaded (fetched $($existing['fetchedAt']))."
    } catch { $existing = $null; Say "Existing live-data.js unreadable -- doing a full pull." }
}
function ExistingPart($name) {
    if ($existing -and $existing.ContainsKey($name)) { return $existing[$name] }
    return $null
}

$payload = [ordered]@{
    fetchedAt = (Get-Date -Format "o")
    source = "$base"
    home = ExistingPart "home"; market = ExistingPart "market"; cpd = ExistingPart "cpd"
    fxDaily = ExistingPart "fxDaily"; fxMonthly = ExistingPart "fxMonthly"
    other = ExistingPart "other"; rateChanges = ExistingPart "rateChanges"
    releases = ExistingPart "releases"; releaseStamp = ExistingPart "releaseStamp"
    monthly = ExistingPart "monthly"; graphs = ExistingPart "graphs"
    daily = ExistingPart "daily"; sdds = ExistingPart "sdds"; mcm = ExistingPart "mcm"
}
if ($null -eq $payload.releaseStamp) { $payload.releaseStamp = @{} }
if ($null -eq $payload.monthly) { $payload.monthly = @{} }
if ($null -eq $payload.graphs) { $payload.graphs = @{} }
if ($null -eq $payload.daily) { $payload.daily = @{} }

# ---------------------------------------------------------------------
#  1. Cheap snapshots -- always refreshed.
# ---------------------------------------------------------------------
Say "Fetching snapshots (home page rates, market rates, FX, other indicators)..."
try {
    $hp = Compact-Snapshot (FetchJson "$base/WebIndicators/HomePageRates")
    if ($hp.Count -lt 8) { throw "only $($hp.Count) home page rates" }
    $payload.home = $hp
    $payload.market = Compact-Snapshot (FetchJson "$base/WebIndicators/CurrentMarketRates")
    $payload.cpd = Compact-Snapshot (FetchJson "$base/WebIndicators/CPDRates")
    $payload.fxDaily = Compact-Snapshot (FetchJson "$base/WebIndicators/HistoricalExchangeRatesDaily")
    $payload.fxMonthly = Compact-Snapshot (FetchJson "$base/WebIndicators/HistoricalExchangeRatesMonthly")
    $payload.other = Compact-Measures (FetchJson "$base/WebIndicators/OtherIndicators")
    Say "  snapshots OK ($($payload.home.Count) home, $($payload.market.Count) market, $($payload.fxDaily.Count) FX pairs)."
} catch { Say "  snapshots failed ($($_.Exception.Message)) -- keeping previous." }

# Historical dates of repo/prime changes -> per-code change series.
try {
    $rows = Compact-Measures (FetchJson "$base/WebIndicators/OtherIndicators/HistoricalDatesOfRateChanges")
    $byCode = [ordered]@{}
    foreach ($r in $rows) {
        $c = $r.code
        if (-not $byCode.Contains($c)) { $byCode[$c] = @{ code = $c; name = $r.name; fmt = $r.fmt; changes = New-Object System.Collections.Generic.List[object] } }
        if ($r.date -and $null -ne $r.value) { $byCode[$c].changes.Add(@($r.date, $r.value)) }
    }
    $rc = New-Object System.Collections.Generic.List[object]
    foreach ($k in $byCode.Keys) { $s = $byCode[$k]; $s.changes = SortObs $s.changes; $rc.Add($s) }
    if ($rc.Count -ge 1) { $payload.rateChanges = $rc.ToArray() }
    Say "  rate-change history OK ($($rc.Count) rate series)."
} catch { Say "  rate-change history failed ($($_.Exception.Message)) -- keeping previous." }

# ---------------------------------------------------------------------
#  2. SDDS sector tables (Economic and Financial Data for South Africa).
# ---------------------------------------------------------------------
Say "Fetching SDDS sector tables..."
try {
    $sdds = @{}
    $sdds.lastUpdate = [string](FetchRaw "$base/WebIndicators/EconFinDataForSA/LastUpdatePeriod") -replace '"', ''
    $sdds.real = Compact-Measures (FetchJson "$base/WebIndicators/EconFinDataForSA/GetRealSectorData")
    $sdds.financial = Compact-Measures (FetchJson "$base/WebIndicators/EconFinDataForSA/GetFinancialSectorData")
    $sdds.external = Compact-Measures (FetchJson "$base/WebIndicators/EconFinDataForSA/GetExternalSectorData")
    $sdds.fiscal = Compact-Measures (FetchJson "$base/WebIndicators/EconFinDataForSA/GetFiscalSectorData")
    $sdds.population = Compact-Measures (FetchJson "$base/WebIndicators/EconFinDataForSA/GetPopulationData")
    try { $sdds.footnotes = @(FetchJson "$base/WebIndicators/EconFinDataForSA/GetFootNotes") } catch { $sdds.footnotes = @() }
    if ($sdds.real.Count -lt 5) { throw "real sector table looks empty" }
    $payload.sdds = $sdds
    Say "  SDDS OK (real $($sdds.real.Count), financial $($sdds.financial.Count), external $($sdds.external.Count), fiscal $($sdds.fiscal.Count))."
} catch { Say "  SDDS failed ($($_.Exception.Message)) -- keeping previous." }

# ---------------------------------------------------------------------
#  3. Statistical releases (1960-onward archives). Only re-pulled when
#     the SARB release register advances -- these are the heavy ones.
# ---------------------------------------------------------------------
Say "Checking release register..."
$releaseTypes = @("MRDMA","MRDBM","MRDIE","MRDFG","MRDCM","MRDEI","CDACSQ","CDACSM","CDASA","CDADS","CDACA","CDACM3")
try {
    $reg = FetchJson "$base/WebIndicators/ReleaseOfSelectedData"
    $payload.releases = @($reg)
    $regMap = @{}
    foreach ($r in $reg) { $regMap[[string]$r["DataType"]] = [string]$r["LastPeriod"] }
    foreach ($dt in $releaseTypes) {
        $have = $null
        if ($payload.releaseStamp.ContainsKey($dt)) { $have = [string]$payload.releaseStamp[$dt] }
        $avail = $null
        if ($regMap.ContainsKey($dt)) { $avail = $regMap[$dt] }
        $held = $payload.monthly.ContainsKey($dt) -and $null -ne $payload.monthly[$dt]
        if ($held -and $have -eq $avail -and -not $Force) { Say "  $dt unchanged ($avail) -- skipping."; continue }
        Say "  $dt downloading full archive (release $avail)..."
        try {
            $series = Compact-Release (FetchJson "$base/WebIndicators/ReleaseOfSelectedData/MonthlyIndicatorsAll/$dt")
            if ($series.Count -lt 3) { throw "only $($series.Count) series" }
            $payload.monthly[$dt] = $series
            $payload.releaseStamp[$dt] = $avail
            $n = 0; foreach ($s in $series) { $n += $s.obs.Count }
            Say "    $dt OK: $($series.Count) series, $n observations."
        } catch { Say "    $dt failed ($($_.Exception.Message)) -- keeping previous." }
    }
} catch { Say "  release register failed ($($_.Exception.Message)) -- keeping previous archives." }

# ---------------------------------------------------------------------
#  4. Curated graph series (SARB's own chart selections, ~3y windows).
# ---------------------------------------------------------------------
Say "Fetching graph series..."
$graphGroups = @{
    MRGMA = "MoneyAndBankingGraphs"; MRGIE = "InternationalEconomicsGraphs"
    MRGCM = "CapitalMarketsGraphs"; MRGFG = "NationalGovernmentGraphs"; MRGEI = "EconomicIndicators"
}
foreach ($gk in @($graphGroups.Keys | Sort-Object)) {
    $ep = $graphGroups[$gk]
    $graphs = @{}
    for ($n = 1; $n -le 8; $n++) {
        try {
            $rows = FetchJson "$base/WebIndicators/ReleaseOfSelectedData/$ep/$n"
            if (-not $rows -or $rows.Count -eq 0) { break }
            $graphs["$n"] = Compact-Graph $rows
        } catch { break }
    }
    if ($graphs.Count -gt 0) { $payload.graphs[$gk] = $graphs; Say "  $gk`: $($graphs.Count) graphs." }
}

# ---------------------------------------------------------------------
#  5. Deep daily history. Codes are discovered from the snapshot lists
#     so new SARB additions get picked up automatically. Majors get
#     full history from 1980; the rest from 2015. Incremental runs
#     fetch only the tail and merge.
# ---------------------------------------------------------------------
Say "Fetching deep daily series..."
$majors = @("EXCX135D","EXCZ001D","EXCZ002D","EXCZ120D","EER4504A","MMRD002A","MMRD000A","MMRD851A","MMRD855A","MMRD708A","MMRD709A")
$dailyCodes = New-Object System.Collections.Generic.List[string]
foreach ($c in $majors) { if (-not $dailyCodes.Contains($c)) { $dailyCodes.Add($c) } }
foreach ($grp in @($payload.fxDaily, $payload.market)) {
    if ($null -eq $grp) { continue }
    foreach ($r in $grp) {
        $c = [string]$r["code"]
        if ($c -and -not $dailyCodes.Contains($c)) { $dailyCodes.Add($c) }
    }
}
$today = Get-Date -Format "yyyy-MM-dd"
$nDaily = 0
foreach ($code in $dailyCodes) {
    $start = "2015-01-01"
    if ($majors -contains $code) { $start = "1980-01-01" }
    $prev = $null
    if ($payload.daily.ContainsKey($code)) { $prev = $payload.daily[$code] }
    if ($prev -and $prev["obs"].Count -gt 0 -and -not $Force) {
        $last = [string]$prev["obs"][$prev["obs"].Count - 1][0]
        try { $start = (Get-Date $last).AddDays(-10).ToString("yyyy-MM-dd") } catch {}
    }
    try {
        $rows = FetchJson "$base/WebIndicators/Shared/GetTimeseriesObservations/$code/$start/$today"
        $fresh = Compact-Obs $rows $true
        if ($null -eq $fresh) { continue }
        if ($prev -and -not $Force -and $start -ne "1980-01-01" -and $start -ne "2015-01-01") {
            # merge: previous obs before the refetch window + fresh tail
            $cut = [string]$fresh.obs[0][0]
            $merged = New-Object System.Collections.Generic.List[object]
            foreach ($o in $prev["obs"]) { if ([string]$o[0] -lt $cut) { $merged.Add(@([string]$o[0], (ToF $o[1]))) } }
            foreach ($o in $fresh.obs) { $merged.Add($o) }
            # NB: $fresh.obs = @($merged) throws "Argument types do not
            # match" in PS 5.1 -- assigning @() of a List into a hashtable
            # member trips ETS overload resolution. ToArray() is safe.
            $fresh.obs = $merged.ToArray()
        }
        $payload.daily[$code] = $fresh
        $nDaily++
    } catch { Say "  $code failed at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message) -- keeping previous." }
}
Say "  daily series OK ($nDaily of $($dailyCodes.Count) refreshed)."

# Monthly/annual deep history: headline CPI & PPI inflation (needed for
# real-rate analysis) plus the annual KBP indicators shown on the
# Other Indicators page. Stored alongside the dailies; periods are
# "YYYY-MM" so the dashboard can tell them apart by length.
Say "Fetching monthly/annual deep series..."
$monDeep = New-Object System.Collections.Generic.List[string]
$monDeep.Add("CPI1000F"); $monDeep.Add("PPI1000F")
foreach ($grp in @($payload.other, $payload.fxMonthly)) {
    if ($null -eq $grp) { continue }
    foreach ($r in $grp) {
        $c = [string]$r["code"]
        if ($c -and -not $monDeep.Contains($c)) { $monDeep.Add($c) }
    }
}
$nMon = 0
foreach ($code in $monDeep) {
    $start = "1960-01-01"
    $prev = $null
    if ($payload.daily.ContainsKey($code)) { $prev = $payload.daily[$code] }
    if ($prev -and $prev["obs"].Count -gt 0 -and -not $Force) {
        $last = [string]$prev["obs"][$prev["obs"].Count - 1][0]
        if ($last.Length -eq 7) { $last = "$last-01" }
        try { $start = (Get-Date $last).AddMonths(-2).ToString("yyyy-MM-dd") } catch {}
    }
    try {
        $rows = FetchJson "$base/WebIndicators/Shared/GetTimeseriesObservations/$code/$start/$today"
        $fresh = Compact-Obs $rows $false
        if ($null -eq $fresh) { continue }
        if ($prev -and -not $Force -and $start -ne "1960-01-01") {
            $cut = [string]$fresh.obs[0][0]
            $merged = New-Object System.Collections.Generic.List[object]
            foreach ($o in $prev["obs"]) { if ([string]$o[0] -lt $cut) { $merged.Add(@([string]$o[0], (ToF $o[1]))) } }
            foreach ($o in $fresh.obs) { $merged.Add($o) }
            # NB: $fresh.obs = @($merged) throws "Argument types do not
            # match" in PS 5.1 -- assigning @() of a List into a hashtable
            # member trips ETS overload resolution. ToArray() is safe.
            $fresh.obs = $merged.ToArray()
        }
        $payload.daily[$code] = $fresh
        $nMon++
    } catch { Say "  $code failed at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message) -- keeping previous." }
}
Say "  monthly/annual deep series OK ($nMon of $($monDeep.Count) refreshed)."

# ---------------------------------------------------------------------
#  6. Money-market operations (MCM) -- auction results, announcements.
# ---------------------------------------------------------------------
Say "Fetching money-market operations..."
try {
    $cats = FetchJson "$base/MCM/Categories"
    $mcm = @{ categories = @(); contributions = @{} }
    foreach ($c in $cats) {
        $id = [string]$c["id"]
        $mcm.categories += @{ id = $id; description = [string]$c["description"]; lastupdate = ([string]$c["lastupdate"]).Trim(); sequence = [int](ToF $c["sequence"]) }
        try { $mcm.contributions[$id] = @(FetchJson "$base/MCM/Contributions/$id") } catch {}
    }
    if ($mcm.categories.Count -ge 5) { $payload.mcm = $mcm; Say "  MCM OK ($($mcm.categories.Count) categories)." }
} catch { Say "  MCM failed ($($_.Exception.Message)) -- keeping previous." }

# ---------------------------------------------------------------------
#  Write out -- only if we actually hold the core datasets.
# ---------------------------------------------------------------------
if (-not $payload.home -or $payload.monthly.Count -eq 0) {
    Say "Core datasets missing (no snapshots or no archives) -- refusing to write a crippled file."
    return
}

# Serialize key-by-key: if a subtree contains anything the serializer
# chokes on (PSObject-wrapped values, DateTime with PowerShell's ETS
# properties, etc.), rebuild just that subtree as plain .NET types
# instead of failing the whole run.
function Plain($o, $depth) {
    if ($depth -gt 40) { return $null }
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $d = @{}
        foreach ($p in $o.PSObject.Properties) { $d[$p.Name] = Plain $p.Value ($depth + 1) }
        return $d
    }
    if ($o -is [string]) { return $o }
    if ($o -is [datetime]) { return $o.ToString("s") }
    if ($o.GetType().IsPrimitive -or $o -is [decimal]) { return $o }
    if ($o -is [System.Collections.IDictionary]) {
        $d = @{}
        foreach ($k in @($o.Keys)) { $d[[string]$k] = Plain $o[$k] ($depth + 1) }
        return $d
    }
    if ($o -is [System.Collections.IEnumerable]) {
        $l = New-Object System.Collections.Generic.List[object]
        foreach ($i in $o) { $l.Add((Plain $i ($depth + 1))) }
        return ,$l
    }
    return [string]$o
}
$parts = New-Object System.Collections.Generic.List[string]
foreach ($k in @($payload.Keys)) {
    $v = $payload[$k]
    $s = $null
    try { $s = $Ser.Serialize($v) }
    catch {
        Say "  note: '$k' needed deep-clean before serializing ($($_.Exception.Message.Split("`n")[0]))"
        $s = $Ser.Serialize((Plain $v 0))
    }
    $parts.Add(($Ser.Serialize([string]$k)) + ":" + $s)
}
$json = "{" + ($parts -join ",") + "}"
$tmpLive = Join-Path $dataDir "live-data.js.tmp"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($tmpLive, "window.SARB_LIVE = " + $json + ";", $utf8NoBom)
Move-Item -Path $tmpLive -Destination $liveDataPath -Force

$mb = [math]::Round((Get-Item $liveDataPath).Length / 1MB, 1)
Say "Done. data/live-data.js written ($mb MB, $($payload.monthly.Count) archives, $($payload.daily.Count) daily series)."
Say "Open (or refresh) SARB_Dashboard.html -- no server needed."
