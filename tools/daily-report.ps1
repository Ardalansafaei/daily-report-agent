#requires -Version 5.1
<#
Daily activity report for the QA workspace (read-only).

One work window (default 08:00-20:00 Asia/Tehran on one date), four lists:
  1. wiki documents I reviewed (user-story review comments)
  2. API endpoints I tested (API-document review comments)
  3. kouleh issues I created
  4. kouleh issues I checked (commented on, closed, or reopened)

Source: the GitLab contribution-events API for the token owner. Every GitLab call
goes through tools\gitlab.ps1 and is a GET; nothing is written to GitLab.
Persian labels live in ..\config\report-config.json so this file stays ASCII-only
(Windows PowerShell 5.1 reads BOM-less scripts as ANSI).
#>
[CmdletBinding()]
param(
  [string]$Date,
  [string]$From = '08:00',
  [string]$To = '20:00',
  [string]$Out,
  [int]$MaxPages = 60,
  [switch]$NoWrite,
  [switch]$ShowCalls
)

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

# ---------------------------------------------------------------- paths

$root = $PSScriptRoot
while ($root -and -not (Test-Path -LiteralPath (Join-Path $root 'tools\gitlab.ps1'))) {
  $parent = Split-Path -Parent $root
  if (-not $parent -or $parent -eq $root) { throw 'repo root not found: no tools\gitlab.ps1 above this script' }
  $root = $parent
}
$GitLabTool = Join-Path $root 'tools\gitlab.ps1'
$AgentDir = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $AgentDir 'config\report-config.json'
$WorkDir = Join-Path $root '.tmp\daily-report'
$ProjectSlug = 'superuni/development/tasks/kouleh'

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "config not found: $ConfigPath" }
$cfg = [IO.File]::ReadAllText($ConfigPath, $utf8) | ConvertFrom-Json
$L = $cfg.labels
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

function Invoke-GitLabTool {
  param([string[]]$ToolArgs, [string]$OutFile)
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $GitLabTool) + $ToolArgs
  if ($OutFile) { $a += @('-Out', $OutFile) }
  if ($ShowCalls) { [Console]::Error.WriteLine('[call] gitlab.ps1 ' + ($ToolArgs -join ' ')) }
  $out = & powershell @a 2>&1
  if ($LASTEXITCODE -ne 0) { throw ('gitlab.ps1 ' + $ToolArgs[0] + ' failed: ' + (($out | ForEach-Object { "$_" }) -join ' ')) }
  , ($out | ForEach-Object { "$_" })
}

# ---------------------------------------------------------------- window

$tz = $null
foreach ($id in @('Iran Standard Time', 'Asia/Tehran')) {
  try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { }
}
if (-not $tz) { $tz = [TimeZoneInfo]::CreateCustomTimeZone('IRST', [TimeSpan]::FromHours(3.5), 'IRST', 'IRST') }

function ConvertTo-GregorianDate([string]$Value) {
  $v = $Value.Trim()
  if ($v -notmatch '^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$') {
    throw "date must be yyyy-MM-dd (Gregorian) or yyyy/MM/dd (Jalali): $Value"
  }
  $y = [int]$Matches[1]; $m = [int]$Matches[2]; $d = [int]$Matches[3]
  if ($y -lt 1700) {
    $pc = New-Object System.Globalization.PersianCalendar
    try { $dt = $pc.ToDateTime($y, $m, $d, 0, 0, 0, 0) } catch { throw "invalid Jalali date: $Value" }
    return $dt.ToString('yyyy-MM-dd', $inv)
  }
  try { $dt = New-Object DateTime($y, $m, $d) } catch { throw "invalid Gregorian date: $Value" }
  $dt.ToString('yyyy-MM-dd', $inv)
}

if (-not $Date) { $Date = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz).ToString('yyyy-MM-dd', $inv) }
else { $Date = ConvertTo-GregorianDate $Date }

$startLocal = [DateTime]::ParseExact(($Date + ' ' + $From), 'yyyy-MM-dd HH:mm', $inv)
$endLocal = [DateTime]::ParseExact(($Date + ' ' + $To), 'yyyy-MM-dd HH:mm', $inv)
$startUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($startLocal, 'Unspecified'), $tz)
$endUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($endLocal, 'Unspecified'), $tz)
if ($endUtc -le $startUtc) { throw '-To must be later than -From' }

function ConvertTo-Utc([string]$Iso) {
  if (-not $Iso) { return $null }
  try { return ([DateTimeOffset]::Parse($Iso, $inv)).UtcDateTime } catch { return $null }
}

function Test-InWindow([string]$Iso) {
  $u = ConvertTo-Utc $Iso
  if ($null -eq $u) { return $false }
  ($u -ge $startUtc -and $u -le $endUtc)
}

# ---------------------------------------------------------------- identity

$meFile = Join-Path $WorkDir 'me.json'
Invoke-GitLabTool @('rest-get', '-ApiPath', '/api/v4/user') $meFile | Out-Null
$meObj = [IO.File]::ReadAllText($meFile, $utf8) | ConvertFrom-Json
$me = $meObj.username
$uid = $meObj.id
if (-not $me -or -not $uid) { throw 'could not read the token owner from /api/v4/user' }

# ---------------------------------------------------------------- events

$events = New-Object 'System.Collections.Generic.List[object]'
$reachedStart = $false
for ($page = 1; $page -le $MaxPages; $page++) {
  $file = Join-Path $WorkDir ('events-{0:d3}.json' -f $page)
  Invoke-GitLabTool @('rest-get', '-ApiPath', "/api/v4/users/$uid/events?per_page=100&page=$page") $file | Out-Null
  $arr = [IO.File]::ReadAllText($file, $utf8) | ConvertFrom-Json
  $n = 0
  $oldest = $null
  foreach ($e in $arr) {
    $n++
    $events.Add($e)
    $c = ConvertTo-Utc $e.created_at
    if ($null -ne $c -and ($null -eq $oldest -or $c -lt $oldest)) { $oldest = $c }
  }
  if ($n -eq 0) { $reachedStart = $true; break }
  if ($null -ne $oldest -and $oldest -lt $startUtc) { $reachedStart = $true; break }
}
if (-not $reachedStart) {
  [Console]::Error.WriteLine('[warn] stopped after ' + $MaxPages + ' event pages before reaching the window start; the report may be incomplete')
}

# ---------------------------------------------------------------- classify

function Get-FieldValue([string]$Body, [string]$Name) {
  $m = [regex]::Match($Body, '(?m)^-\s*' + [regex]::Escape($Name) + '\s*:\s*(.+?)\s*$')
  if ($m.Success) { $m.Groups[1].Value.Trim().Trim('`') } else { '' }
}

function Get-NoteKind([string]$Body) {
  foreach ($k in $cfg.apiMarkers) { if ($Body.Contains($k)) { return 'api' } }
  foreach ($k in $cfg.storyMarkers) { if ($Body.Contains($k)) { return 'story' } }
  'other'
}

$storyDocs = @{}
$apiDocs = @{}
$createdIssues = @{}
$checkedIssues = @{}
$otherWiki = 0

foreach ($e in $events) {
  if ($e.author_username -ne $me) { continue }
  if (-not (Test-InWindow $e.created_at)) { continue }
  $action = $e.action_name
  $note = $e.note

  if ($action -eq 'commented on' -and $note -and $note.noteable_type -eq 'WikiPage::Meta') {
    $body = [string]$note.body
    $kind = Get-NoteKind $body
    $pageTitle = [string]$e.target_title
    if ($kind -eq 'story') {
      $title = Get-FieldValue $body $cfg.fields.storyTitle
      if (-not $title) { $title = $pageTitle }
      $key = $pageTitle
      if (-not $storyDocs.ContainsKey($key)) { $storyDocs[$key] = [pscustomobject]@{ Title = $title; Count = 0 } }
      $storyDocs[$key].Count++
      if ($title) { $storyDocs[$key].Title = $title }
    }
    elseif ($kind -eq 'api') {
      $mm = [regex]::Match($body, '(?m)^-\s*\[x\]\s*(GET|POST|PUT|PATCH|DELETE)\b')
      $method = if ($mm.Success) { $mm.Groups[1].Value } else { '' }
      $path = Get-FieldValue $body $cfg.fields.path
      $key = (($method + ' ' + $path).Trim()).ToLowerInvariant()
      if (-not $key) { $key = 'note ' + $note.id }
      $service = Get-FieldValue $body $cfg.fields.serviceName
      if (-not $apiDocs.ContainsKey($key)) {
        $apiDocs[$key] = [pscustomobject]@{ Service = $service; Method = $method; Path = $path; Count = 0 }
      }
      $apiDocs[$key].Count++
      if ($service) { $apiDocs[$key].Service = $service }
      if ($method) { $apiDocs[$key].Method = $method }
      if ($path) { $apiDocs[$key].Path = $path }
    }
    else { $otherWiki++ }
    continue
  }

  if ($action -eq 'commented on' -and $note -and $note.noteable_type -eq 'Issue') {
    $iid = [int]$note.noteable_iid
    $key = [string]$iid
    if (-not $checkedIssues.ContainsKey($key)) {
      $checkedIssues[$key] = [pscustomobject]@{ Iid = $iid; Title = [string]$e.target_title; Count = 0; Changed = $false }
    }
    $checkedIssues[$key].Count++
    continue
  }

  if ($action -eq 'opened' -and ($e.target_type -eq 'Issue' -or $e.target_type -eq 'WorkItem')) {
    $iid = [int]$e.target_iid
    $key = [string]$iid
    if (-not $createdIssues.ContainsKey($key)) {
      $createdIssues[$key] = [pscustomobject]@{ Iid = $iid; Title = [string]$e.target_title }
    }
    continue
  }

  if (($action -eq 'closed' -or $action -eq 'reopened') -and ($e.target_type -eq 'Issue' -or $e.target_type -eq 'WorkItem')) {
    $iid = [int]$e.target_iid
    $key = [string]$iid
    if (-not $checkedIssues.ContainsKey($key)) {
      $checkedIssues[$key] = [pscustomobject]@{ Iid = $iid; Title = [string]$e.target_title; Count = 0; Changed = $false }
    }
    $checkedIssues[$key].Changed = $true
    continue
  }
}

# ---------------------------------------------------------------- issue states

$stateMap = @{}
$wanted = @(@($createdIssues.Keys) + @($checkedIssues.Keys) | Sort-Object -Unique)
if ($wanted.Count -gt 0) {
  $encodedProject = [Uri]::EscapeDataString($ProjectSlug)
  for ($i = 0; $i -lt $wanted.Count; $i += 50) {
    $last = [Math]::Min($i + 49, $wanted.Count - 1)
    $chunk = @($wanted[$i..$last])
    $q = (@($chunk | ForEach-Object { 'iids%5B%5D=' + $_ }) -join '&')
    $apiPath = "/api/v4/projects/$encodedProject/issues?scope=all&per_page=100&$q"
    $file = Join-Path $WorkDir ('states-{0:d2}.json' -f [int]($i / 50))
    try {
      Invoke-GitLabTool @('rest-get', '-ApiPath', $apiPath) $file | Out-Null
      $arr = [IO.File]::ReadAllText($file, $utf8) | ConvertFrom-Json
      foreach ($it in $arr) { $stateMap[[string]$it.iid] = [string]$it.state }
    }
    catch {
      [Console]::Error.WriteLine('[warn] issue state batch failed: ' + $_.Exception.Message)
    }
  }
  foreach ($key in $wanted) {
    if ($stateMap.ContainsKey([string]$key)) { continue }
    $file = Join-Path $WorkDir ('issue-' + $key + '.md')
    try {
      Invoke-GitLabTool @('issue-get', '-Iid', [string]$key) $file | Out-Null
      $head = [regex]::Match([IO.File]::ReadAllText($file, $utf8), '(?m)^#\d+ \[(\w+)\]')
      if ($head.Success) { $stateMap[[string]$key] = $head.Groups[1].Value }
    }
    catch {
      [Console]::Error.WriteLine('[warn] issue ' + $key + ' state unknown: ' + $_.Exception.Message)
    }
  }
}

# ---------------------------------------------------------------- render

function Get-StateLabel([string]$State) {
  if ($State -eq 'closed') { return $L.closed }
  if ($State -eq 'opened') { return $L.open }
  if ($State) { return $State }
  $L.unknown
}

$storyItems = @($storyDocs.Values | Sort-Object @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Title } })
$apiItems = @($apiDocs.Values | Sort-Object @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Service } })
$createdItems = @($createdIssues.Values | Sort-Object Iid)
$checkedItems = @($checkedIssues.Values | Sort-Object Iid)
$storyNoteCount = [int](@($storyItems | Measure-Object -Property Count -Sum).Sum)
$apiNoteCount = [int](@($apiItems | Measure-Object -Property Count -Sum).Sum)

$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add('# ' + $L.reportTitle + ' - ' + $Date)
$lines.Add('')
$lines.Add($L.windowLine.Replace('{from}', $From).Replace('{to}', $To))

$lines.Add('')
$lines.Add('## ' + $L.section1)
$lines.Add($L.total + ': ' + $storyItems.Count + ' ' + $L.documents + ' - ' + $storyNoteCount + ' ' + $L.comments)
if ($storyItems.Count -eq 0) { $lines.Add('- ' + $L.empty) }
foreach ($s in $storyItems) { $lines.Add('- ' + $s.Title + ' - ' + $s.Count + ' ' + $L.comments) }

$lines.Add('')
$lines.Add('## ' + $L.section2)
$lines.Add($L.total + ': ' + $apiItems.Count + ' ' + $L.endpoints + ' - ' + $apiNoteCount + ' ' + $L.comments)
if ($apiItems.Count -eq 0) { $lines.Add('- ' + $L.empty) }
foreach ($a in $apiItems) {
  $label = $a.Service
  if (-not $label) { $label = $a.Path }
  if (-not $label) { $label = $L.unknown }
  $endpoint = (($a.Method + ' ' + $a.Path).Trim())
  if ($endpoint) { $lines.Add('- ' + $label + ' - `' + $endpoint + '`') }
  else { $lines.Add('- ' + $label) }
}

$lines.Add('')
$lines.Add('## ' + $L.section3)
$lines.Add($L.total + ': ' + $createdItems.Count + ' ' + $L.issues)
if ($createdItems.Count -eq 0) { $lines.Add('- ' + $L.empty) }
foreach ($i in $createdItems) { $lines.Add('- #' + $i.Iid + ' ' + $i.Title) }

$lines.Add('')
$lines.Add('## ' + $L.section4)
$lines.Add($L.total + ': ' + $checkedItems.Count + ' ' + $L.issues)
if ($checkedItems.Count -eq 0) { $lines.Add('- ' + $L.empty) }
foreach ($i in $checkedItems) {
  $state = ''
  if ($stateMap.ContainsKey([string]$i.Iid)) { $state = $stateMap[[string]$i.Iid] }
  $lines.Add('- #' + $i.Iid + ' ' + $i.Title + ' - ' + $L.state + ': ' + (Get-StateLabel $state))
}

$lines.Add('')
$lines.Add($L.sourceLine)

$report = ($lines -join "`n").TrimEnd() + "`n"

if (-not $NoWrite) {
  if (-not $Out) { $Out = Join-Path $WorkDir ('report-' + $Date + '.md') }
  if (-not [IO.Path]::IsPathRooted($Out)) { $Out = Join-Path $root $Out }
  $dir = Split-Path -Parent $Out
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Out, $report, $utf8)
  [Console]::Error.WriteLine('[report] ' + $Out)
}

Write-Output $report
