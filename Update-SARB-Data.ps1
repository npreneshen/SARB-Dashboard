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
# ---------------------------------------------------------------------
#  The KBP "Quarterly Bulletin" download facility -- a SEPARATE numbering
#  scheme (KBPnnnn, ~2300 codes) from the WebIndicators statistical
#  releases used above. Several codes that are cataloged (with a
#  description) return nothing at all through WebIndicators'
#  GetTimeseriesObservations -- confirmed by direct testing, not a code
#  format issue -- but ARE retrievable through this separate endpoint:
#    https://www.resbank.co.za/bin/sarb/custom/downloadfacility
#      ?onlineDownload=sSRSData&sSRSDataTsCodes=<code1>,<code2>,...
#      &sSRSDataFrequencyDescription=Monthly
#      &sSRSDataStartDate=YYYY/MM&sSRSDataEndDate=YYYY/MM
#  No CORS header and no auth needed (confirmed; the "admin:admin" basic
#  auth some captures show is unused by the server -- plain GET works).
#  Because there's no CORS, this can only be called from here (or any
#  other server-side context) -- never from the browser page directly.
#  The endpoint sits behind an F5 WAF that rejects the whole request
#  once too many codes are packed into one query string (empirically:
#  11 codes OK, 12 rejected) -- batch conservatively below that.
# ---------------------------------------------------------------------
# Circuit breaker: this endpoint has shown real intermittent instability per
# frequency type (observed directly -- "Quarterly" worked, then failed
# consistently minutes later with nothing changed on our end). Without a
# breaker, a genuinely-down frequency would retry-storm through every
# remaining batch (each already paying FetchRaw's own 3-try backoff) for
# potentially hours on a large catalog. Stop after 3 consecutive batch
# failures and leave the rest pending for the next run instead.
function FetchDownloadFacility($codes, $freqDesc, $fromYM, $toYM, $batchSize) {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $batchSize) { $batchSize = 8 }
    $consecutiveFail = 0
    for ($i = 0; $i -lt $codes.Count; $i += $batchSize) {
        if ($consecutiveFail -ge 3) {
            $remaining = $codes.Count - $i
            Say "    ${freqDesc}: 3 consecutive batch failures -- stopping early, $remaining codes left pending for next run."
            break
        }
        $end = [math]::Min($i + $batchSize - 1, $codes.Count - 1)
        $batch = $codes[$i..$end]
        $codesParam = [string]::Join(",", $batch)
        $url = "https://www.resbank.co.za/bin/sarb/custom/downloadfacility?onlineDownload=sSRSData&sSRSDataTsCodes=$codesParam&sSRSDataFrequencyDescription=$freqDesc&sSRSDataStartDate=$fromYM&sSRSDataEndDate=$toYM"
        try {
            $obj = $Ser.DeserializeObject((FetchRaw $url))
            # A 200 response with an empty diffgram means "no data for these
            # codes in this range" (not an error, not worth retrying) --
            # distinct from a genuine transport failure, which throws before
            # we ever get here. Indexing straight into ["TsObservations"]
            # ["Table"] on that empty shape throws "Cannot index into a null
            # array" and used to get miscounted as a real batch failure,
            # feeding the circuit breaker for something a retry can't fix.
            $diffgram = $obj["xs:ssrsDataResult"]["diffgr:diffgram"]
            $tsObs = $diffgram["TsObservations"]
            if ($null -ne $tsObs) {
                $tbl = $tsObs["Table"]
                if ($tbl -is [System.Collections.IDictionary]) { $tbl = @($tbl) }
                foreach ($row in $tbl) { $rows.Add($row) }
            }
            $consecutiveFail = 0
        } catch {
            Say "    KBP batch failed ($codesParam): $($_.Exception.Message)"
            $consecutiveFail++
        }
        Start-Sleep -Milliseconds 600
    }
    return ,$rows.ToArray()
}
function Compact-KBP($rows, $freqUsed, $manifestDescByCode) {
    # Period is an 8-digit YYYYMMDD integer, but what the trailing components
    # actually MEAN varies by code, not just by the requested frequency:
    #  - Daily codes (row Specification "D6"): dd is a real calendar day.
    #  - Weekly codes (Specification "W5"): dd is a WEEK-OF-MONTH INDEX
    #    (1-5), not a day -- confirmed directly (KBP1490W runs 20260401,
    #    20260402, 20260403, 20260404, then 20260501..20260505 -- April has
    #    4 weeks, May has 5). The SARB's own site labels these "2026/04/W4"
    #    etc. Reading dd as a literal day-of-month (the original approach)
    #    produced dates only ~1 day apart instead of ~7, and never matched
    #    the SARB's own reference labels.
    #  - Monthly codes: dd is always "00", mm is a real calendar month.
    #  - "Yearly" codes (Specification "K1") are NOT all the same shape:
    #    some are genuinely one-point-a-year (mm always "00", e.g.
    #    KBP1420J-style codes), but some are quarterly SURVEY data with the
    #    QUARTER NUMBER (1-4) packed into the month slot instead (confirmed
    #    directly: KBP7143K, a BER inflation-expectations series, runs
    #    20250100/0200/0300/0400 for 2025 Q1-Q4, every one tagged "K1" --
    #    the exact same Specification as genuine one-point-a-year codes).
    #    Specification alone can't tell these apart; only the code's OWN
    #    full value range can -- if dd is always "00" and mm only ever
    #    takes values 1-4 across the code's entire history, it's a quarter
    #    number, not a month (a real monthly series would eventually show
    #    mm > 4 somewhere in its history).
    $byCode = [ordered]@{}
    foreach ($r in $rows) {
        $code = [string]$r["TimeSeriesCode"]
        if (-not $code) { continue }
        if (-not $byCode.Contains($code)) {
            $desc = (([string]$r["LongDesc"]) -replace '<br\s*/?>', ' -- ' -replace '\s+', ' ').Trim()
            # The SARB's own LongDesc field is truncated to a fixed length AND
            # occasionally carries a stray internal space where a word wrapped in
            # their source system (e.g. "Compensati on for employees", or cut off
            # entirely mid-word) -- the manifest's description, built from their
            # separate "QB TimeSeries Descriptions" Excel, is consistently the
            # fuller, cleaner text (confirmed: normalising both to remove all
            # whitespace, the API's text is a truncated PREFIX of the manifest's in
            # the overwhelming majority of cases that differ at all). Prefer the
            # manifest whenever it's an exact match modulo whitespace, or a fuller
            # version of a truncated API string; keep the API's own text only when
            # IT is the fuller one (a handful of codes where the manifest only has
            # a shared generic prefix and the API carries the specific sub-item).
            if ($manifestDescByCode -and $manifestDescByCode.Contains($code)) {
                $md = $manifestDescByCode[$code]
                if ($md) {
                    $nApi = $desc -replace '\s',''
                    $nMan = $md -replace '\s',''
                    if ($nApi -eq $nMan -or ($nMan.StartsWith($nApi) -and $nApi.Length -gt 0)) { $desc = $md }
                }
            }
            $byCode[$code] = @{
                code = $code; name = $desc; unit = [string]$r["UnitOfMeasure"]
                raw = New-Object System.Collections.Generic.List[object]
            }
            if ($freqUsed) { $byCode[$code].freq = $freqUsed }
        }
        $periodRaw = [string]$r["Period"]
        $v = ToF $r["Value"]
        if ($null -ne $v -and $periodRaw.Length -ge 6) {
            $byCode[$code].raw.Add(@{ period = $periodRaw; spec = [string]$r["Specification"]; value = $v })
        }
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in $byCode.Keys) {
        $s = $byCode[$k]
        $raws = $s.raw
        $isWeekly = ($raws | Where-Object { $_.spec -eq "W5" } | Select-Object -First 1) -ne $null
        $allDayZero = $true; $maxMonth = 0; $anyMonthNonzero = $false
        foreach ($ro in $raws) {
            if ($ro.period.Length -ge 8) {
                $mm = [int]$ro.period.Substring(4,2); $dd = $ro.period.Substring(6,2)
                if ($dd -ne "00") { $allDayZero = $false }
                if ($mm -gt $maxMonth) { $maxMonth = $mm }
                if ($mm -ne 0) { $anyMonthNonzero = $true }
            }
        }
        $isQuarterEncoded = $allDayZero -and $anyMonthNonzero -and ($maxMonth -le 4)
        $obs = New-Object System.Collections.Generic.List[object]
        foreach ($ro in $raws) {
            $periodRaw = $ro.period
            $p = $null
            if ($periodRaw.Length -ge 8) {
                $yyyy = $periodRaw.Substring(0,4); $mm = $periodRaw.Substring(4,2); $dd = $periodRaw.Substring(6,2)
                if ($isQuarterEncoded) {
                    if ($mm -ne "00") { $p = "$yyyy-{0:D2}" -f ([int]$mm * 3) }  # quarter-end month (Q1->Mar, ..., Q4->Dec)
                } elseif ($isWeekly -and $dd -ne "00") {
                    $wk = [int]$dd
                    $dim = [DateTime]::DaysInMonth([int]$yyyy, [int]$mm)
                    $day = [Math]::Min($dim, $wk * 7)
                    $p = "$yyyy-$mm-{0:D2}" -f $day
                } elseif ($dd -ne "00") { $p = "$yyyy-$mm-$dd" }
                elseif ($mm -ne "00") { $p = "$yyyy-$mm" }
                else { $p = "$yyyy-01" }
            } elseif ($periodRaw.Length -ge 6) {
                $p = "$($periodRaw.Substring(0,4))-$($periodRaw.Substring(4,2))"
            }
            if ($p) { $obs.Add(@($p, $ro.value)) }
        }
        $s.obs = SortObs $obs
        $s.Remove("raw")
        $out.Add($s)
    }
    return ,$out.ToArray()
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
    kbp = ExistingPart "kbp"
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
# Balance-of-payments goods trade (quarterly) and merchandise trade totals
# (monthly) -- the SDDS external-sector snapshot only exposes the latest
# value, but full deep history is available through this same reliable,
# CORS-open endpoint. Deliberately NOT the KBP5000J/KBP5003J download-
# facility codes for the "same" concept -- confirmed directly those are
# stuck at annual-only granularity no matter which frequency parameter is
# used (even the SARB's own public Online Statistical Query tool hits the
# exact same endpoint and would face the same limitation), while these K-
# suffix/CUR-prefix codes give genuine quarterly/monthly data back to 2000/
# 2012 respectively.
#
# The same K-suffix-vs-J-suffix pattern was confirmed across the WHOLE
# balance-of-payments current/financial-account family (checked against a
# fuller SARB code list the user supplied): all 19 K-suffix codes below
# return genuine current quarterly data, while their J-suffix download-
# facility counterparts (now removed from kbp-manifest.json entirely, to
# avoid holding a strictly-worse duplicate) were stuck at annual. This is
# NOT true of KBP codes generally -- a broad sample of ~25 other unrelated
# base codes showed neither suffix reachable via WebIndicators at all, so
# this fix is specific to this BOP-headline family, not a general rule.
foreach ($c in @(
    "KBP5000K","KBP5003K","KBP5007K","KBP5002K","KBP5004K","KBP5680K","KBP5681K",
    "KBP5682K","KBP5764K","KBP5656K","KBP5640K","KBP5660K","KBP5644K","KBP5677K",
    "KBP5672K","KBP5666K","KBP5650K","KBP5679K","KBP5766K",
    "CURX600A","CURM600A"
)) { $monDeep.Add($c) }
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
#  7. KBP gap-fill series -- codes cataloged in the SARB's own Quarterly
#     Bulletin data but not reachable through WebIndicators: credit-card
#     activity, and (critically) the government bond yield MATURITY
#     BUCKETS (0-3y/3-5y/5-10y/10-15y/20-30y) needed for a real curve
#     shape instead of just two individual bonds plus two rough averages.
# ---------------------------------------------------------------------
# The full catalog (~2,320 codes, in kbp-manifest.json next to this script,
# built from the SARB's own "QB TimeSeries Descriptions" Excel) is fetched
# incrementally: codes already held from a previous run are skipped unless
# -Force, so this completes gradually across runs rather than requiring one
# huge fetch to succeed in a single sitting.
#
# What looked like pure server-side instability on "Quarterly" turned out to
# be mostly a manifest data-quality issue: a user-verified example (KBP1420J)
# showed the manifest's own Frequency column was simply wrong for a huge
# share of Quarterly-tagged codes -- they're really Yearly. The Quarterly
# GROUP batch still reliably 500s (real, but now a symptom rather than the
# whole story), while the frequency-fallback pass below recovers the actual
# data for almost all of them by retrying as Yearly. Genuine server flakiness
# still shows up occasionally on Weekly/Daily group batches; a run that
# doesn't clear everything is a normal partial success, and the next run
# (or the fallback pass) picks up where this one left off.
Say "Fetching KBP gap-fill series (credit card, bond yield buckets, catalog)..."
try {
    $manifestPath = Join-Path $dir "kbp-manifest.json"
    if (-not (Test-Path $manifestPath)) { throw "kbp-manifest.json not found next to the script" }
    $manifest = $Ser.DeserializeObject([IO.File]::ReadAllText($manifestPath))
    $manifestDescByCode = @{}
    foreach ($entry in $manifest) { $manifestDescByCode[[string]$entry["code"]] = [string]$entry["desc"] }
    $existingKbp = if ($payload.kbp) { $payload.kbp } else { @{} }
    # A year/month-only date (no day) was the format used here originally;
    # a user-supplied working URL for a previously-failing code used a full
    # yyyy/MM/dd date instead, so this now always sends a real day component.
    $toYM = Get-Date -Format "yyyy/MM/dd"
    # Codes already held get a small recent-window TOP-UP check for new
    # observations instead of being skipped forever (the original behaviour --
    # a held code's data was correct as of whenever it was first fetched and
    # NEVER refreshed again after that, silently). Brand-new codes still get
    # the full 1960-to-today history fetch. This is what makes future runs,
    # once the catalog is essentially complete, genuinely small/fast: almost
    # every code falls into the cheap top-up path, not the full-history one.
    $byFreq = @{}
    $topUpByFreq = @{}
    $skipped = 0
    foreach ($entry in $manifest) {
        $code = [string]$entry["code"]
        $freq = [string]$entry["freq"]
        $held = $existingKbp.ContainsKey($code) -and $existingKbp[$code].obs.Count -gt 0
        if ($held -and -not $Force) {
            # Prefer the frequency PROVEN to work for this code (recorded by
            # Compact-KBP when it was first fetched, possibly via the fallback
            # pass below) over the manifest's own tag, which is wrong for a
            # large share of codes -- otherwise the top-up would repeat the
            # exact same failing request every single run for those.
            $topUpFreq = if ($existingKbp[$code].freq) { [string]$existingKbp[$code].freq } else { $freq }
            if (-not $topUpByFreq.ContainsKey($topUpFreq)) { $topUpByFreq[$topUpFreq] = New-Object System.Collections.Generic.List[string] }
            $topUpByFreq[$topUpFreq].Add($code)
            $skipped++
            continue
        }
        if (-not $byFreq.ContainsKey($freq)) { $byFreq[$freq] = New-Object System.Collections.Generic.List[string] }
        $byFreq[$freq].Add($code)
    }
    Say "  $($manifest.Count) codes in catalog, $skipped already held (top-up check), $($manifest.Count - $skipped) new this run."
    $kbpMap = @{}
    foreach ($k in $existingKbp.Keys) { $kbpMap[$k] = $existingKbp[$k] }
    $totalNew = 0
    # Process the reliable, high-yield groups first (Monthly/Yearly have run
    # clean at 99-100%); Quarterly is by far the largest group but the one
    # that's shown real intermittent server-side instability, so it goes
    # last -- if it has a bad run, everything else is still banked. Daily
    # and Weekly frequency strings carry spaces/parentheses (URL-encoded),
    # making each code's share of the query string longer, and batches of 8
    # hit connection resets there even though single-code requests worked;
    # smaller batches for those two tiny groups avoids it cheaply.
    $freqOrder = @("Monthly", "Yearly", "Weekly (5 days)", "Daily (6 Days)", "Quarterly")
    $batchSizes = @{ "Monthly" = 8; "Yearly" = 8; "Quarterly" = 5; "Weekly (5 days)" = 2; "Daily (6 Days)" = 2 }
    foreach ($freq in $freqOrder) {
        if (-not $byFreq.ContainsKey($freq)) { continue }
        $codes = $byFreq[$freq]
        Say "  Fetching $($codes.Count) $freq codes..."
        try {
            $rows = FetchDownloadFacility $codes.ToArray() $freq "1960/01/01" $toYM $batchSizes[$freq]
            $series = Compact-KBP $rows $freq $manifestDescByCode
            foreach ($s in $series) { $kbpMap[$s.code] = $s; $totalNew++ }
            Say "    $freq OK: $($series.Count) of $($codes.Count) series returned data."
        } catch { Say "    $freq failed ($($_.Exception.Message)) -- codes remain pending for next run." }
    }
    # Top-up pass for already-held codes: a generous 15-month lookback
    # comfortably covers even Annual data's once-a-year publication lag
    # while keeping each request small. New observations are merged onto the
    # existing history (de-duplicated by date), never replacing it outright --
    # a failed or empty top-up for a code just leaves its existing data as-is.
    $topUpFrom = (Get-Date).AddMonths(-15).ToString("yyyy/MM/dd")
    $topUpNew = 0
    foreach ($freq in $freqOrder) {
        if (-not $topUpByFreq.ContainsKey($freq)) { continue }
        $codes = $topUpByFreq[$freq]
        Say "  Checking $($codes.Count) already-held $freq code(s) for new data..."
        try {
            $rows = FetchDownloadFacility $codes.ToArray() $freq $topUpFrom $toYM $batchSizes[$freq]
            $series = Compact-KBP $rows $freq $manifestDescByCode
            foreach ($s in $series) {
                $existing = $kbpMap[$s.code]
                if (-not $existing) { $kbpMap[$s.code] = $s; $topUpNew++; continue }
                $merged = New-Object System.Collections.Generic.List[object]
                $seen = @{}
                foreach ($o in $existing.obs) { $k = [string]$o[0]; if (-not $seen.ContainsKey($k)) { $merged.Add($o); $seen[$k] = $true } }
                $added = 0
                foreach ($o in $s.obs) { $k = [string]$o[0]; if (-not $seen.ContainsKey($k)) { $merged.Add($o); $seen[$k] = $true; $added++ } }
                if ($added -gt 0) { $existing.obs = SortObs $merged; $topUpNew++ }
            }
        } catch { Say "    $freq top-up failed ($($_.Exception.Message)) -- will retry next run." }
    }
    if ($topUpNew -gt 0) { Say "  Top-up refreshed $topUpNew already-held code(s) with new observations." }
    # Frequency-fallback pass: a user-verified example (KBP1420J) showed the
    # manifest's own "Frequency" column is occasionally wrong for a specific
    # code -- classified here as Quarterly, but only "Yearly" actually returns
    # data for it. Rather than trust the manifest blindly, codes still unheld
    # after the normal per-group pass get one single-code retry against the
    # frequency family's sibling before being left pending. Bounded to a fixed
    # request budget so a large batch of genuinely-wrong codes can't blow out
    # this run's time -- remaining ones just get picked up on a future run.
    $FREQ_FALLBACK = @{
        "Quarterly" = @("Yearly"); "Yearly" = @("Quarterly")
        "Weekly (5 days)" = @("Daily (6 Days)"); "Daily (6 Days)" = @("Weekly (5 days)")
    }
    $fallbackBudget = 1400
    $fallbackNew = 0
    foreach ($freq in $freqOrder) {
        if ($fallbackBudget -le 0) { break }
        if (-not $byFreq.ContainsKey($freq)) { continue }
        $alts = $FREQ_FALLBACK[$freq]
        if (-not $alts) { continue }
        foreach ($code in $byFreq[$freq]) {
            if ($kbpMap.ContainsKey($code)) { continue }
            if ($fallbackBudget -le 0) { break }
            foreach ($alt in $alts) {
                $fallbackBudget--
                try {
                    $altRows = FetchDownloadFacility @($code) $alt "1960/01/01" $toYM 1
                    $altSeries = Compact-KBP $altRows $alt $manifestDescByCode
                    if ($altSeries.Count -gt 0) { $kbpMap[$altSeries[0].code] = $altSeries[0]; $fallbackNew++; break }
                } catch {}
                if ($fallbackBudget -le 0) { break }
            }
        }
    }
    if ($fallbackNew -gt 0) { Say "  Frequency-fallback recovered $fallbackNew code(s) misclassified in the manifest." }
    if ($kbpMap.Count -ge 5) {
        $payload.kbp = $kbpMap
        # Baked into the deployed sidecar so a page load can tell whether the
        # Cloudflare Worker's own KV (see cloudflare/) has picked up anything
        # newer than THIS deploy since it went out, without needing to
        # unconditionally re-download the Worker's multi-MB dataset every
        # single time -- only when it's actually ahead of what's already here.
        $payload.kbpStamp = (Get-Date).ToString("o")
        Say "  KBP total held: $($kbpMap.Count) of $($manifest.Count) catalog codes ($totalNew new this run)."
    } else {
        Say "  KBP fetch returned too few series ($($kbpMap.Count)) -- keeping previous."
    }
} catch { Say "  KBP fetch failed ($($_.Exception.Message)) -- keeping previous." }

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
