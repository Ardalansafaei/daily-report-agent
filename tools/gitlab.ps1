#requires -Version 5.1
<#
GitLab helper for this QA workspace. Usage and recipes: docs/agent/gitlab-tool.md
Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Command = 'help',
  [string]$Slug,
  [string]$NoteId,
  [string]$DiscussionId,
  [string]$BodyFile,
  [string]$Title,
  [string]$Labels,
  [string]$Assignee,
  [int]$Iid,
  [string]$Search,
  [string]$State = 'all',
  [string]$Project,
  [string]$ApiPath,
  [string]$QueryFile,
  [string]$VariablesJson,
  [string]$Ref = 'HEAD',
  [string]$Out,
  [switch]$Remote,
  [switch]$Notes,
  [switch]$IncludeSystem,
  [switch]$Approved,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$WikiProject = 'superuni/development/analyze/dormitory-bpms'
$DefaultTasksProject = 'superuni/development/tasks/kouleh'
$WikiClone = Join-Path $RepoRoot 'wiki-ro'
$ForbiddenLabels = @('PO Verify', 'Dormitory::Dashboard')
$Utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- config

function Read-DotEnv {
  $path = Join-Path $RepoRoot '.env'
  if (-not (Test-Path -LiteralPath $path)) { throw ".env not found at $RepoRoot" }
  $values = @{}
  foreach ($line in [IO.File]::ReadAllLines($path, $Utf8)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    $values[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
  }
  $values
}

$script:Cfg = $null
function Get-Cfg {
  if (-not $script:Cfg) {
    $e = Read-DotEnv
    foreach ($k in @('GITLAB_URL', 'GITLAB_TOKEN')) {
      if (-not $e[$k]) { throw "$k is missing in .env" }
    }
    $tasks = $e['GITLAB_TASKS_PROJECT']
    if (-not $tasks) { $tasks = $DefaultTasksProject }
    $script:Cfg = @{
      Url   = $e['GITLAB_URL'].TrimEnd('/')
      Token = $e['GITLAB_TOKEN']
      Proxy = $e['HTTP_PROXY_URL']
      Tasks = $tasks
    }
  }
  $script:Cfg
}

# ---------------------------------------------------------------- helpers

function Resolve-UserPath([string]$PathValue) {
  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PathValue)
}

function Write-Result([string]$Text) {
  if ($Out) {
    $full = Resolve-UserPath $Out
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [IO.File]::WriteAllText($full, $Text, $Utf8)
    Write-Output "written $full ($($Text.Length) chars)"
  } else {
    Write-Output $Text
  }
}

function Write-Note([string]$Message) { [Console]::Error.WriteLine($Message) }

function Assert-Approved([string]$What) {
  if (-not $Approved) {
    throw "$What changes GitLab. Re-run with -Approved only after the user explicitly approved this exact text, or use -DryRun."
  }
}

function Normalize-Text([string]$Text) {
  if ($null -eq $Text) { return '' }
  $Text.Replace("`r`n", "`n").TrimEnd("`n")
}

function Read-BodyFile {
  if (-not $BodyFile) { throw '-BodyFile is required' }
  $full = Resolve-UserPath $BodyFile
  if (-not (Test-Path -LiteralPath $full)) { throw "body file not found: $full" }
  $text = [IO.File]::ReadAllText($full, $Utf8).Replace("`r`n", "`n")
  $lines = $text -split "`n"
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq '```markdown') { $start = $i; break }
  }
  if ($start -ge 0) {
    $end = -1
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
      if ($lines[$j].Trim() -eq '```') { $end = $j; break }
    }
    if ($end -lt 0) { throw "the markdown fence in $full is not closed" }
    if ($end -eq $start + 1) { $body = '' } else { $body = $lines[($start + 1)..($end - 1)] -join "`n" }
  } else {
    $body = $text
  }
  $body = $body.Trim("`n")
  if (-not $body.Trim()) { throw "body is empty in $full" }
  $body
}

function ConvertTo-Slug([string]$Value) {
  if (-not $Value) { throw '-Slug is required (wiki slug or full wiki URL)' }
  $s = $Value.Trim().Trim('<', '>')
  $s = $s.Replace('\(', '(').Replace('\)', ')')
  $i = $s.IndexOf('/-/wikis/')
  if ($i -ge 0) { $s = $s.Substring($i + 9) }
  $s = ($s -split '[#?]')[0]
  $s = [Uri]::UnescapeDataString($s).Trim('/')
  if ($s.EndsWith('.md')) { $s = $s.Substring(0, $s.Length - 3) }
  $s
}

function Get-WikiPageUrl([string]$PageSlug) {
  (Get-Cfg).Url + '/' + $WikiProject + '/-/wikis/' + $PageSlug
}

function ConvertTo-NoteGid([string]$Value) {
  if (-not $Value -and $Slug -match 'note_(\d+)') { $Value = $Matches[1] }
  if (-not $Value) { throw '-NoteId is required (number, gid, or URL with #note_)' }
  if ($Value -match 'note_(\d+)') { return "gid://gitlab/Note/$($Matches[1])" }
  if ($Value -match '^gid://gitlab/Note/\d+$') { return $Value }
  if ($Value -match '^\d+$') { return "gid://gitlab/Note/$Value" }
  throw "cannot read a note id from: $Value"
}

function ConvertTo-DiscussionGid([string]$Value) {
  if (-not $Value) { return $null }
  if ($Value.StartsWith('gid://')) { return $Value }
  "gid://gitlab/Discussion/$Value"
}

function Split-Labels([string]$Value) {
  @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ---------------------------------------------------------------- http

function Get-WebException($ErrorRecord) {
  $ex = $ErrorRecord.Exception
  while ($ex) {
    if ($ex -is [System.Net.WebException]) { return $ex }
    $ex = $ex.InnerException
  }
  $null
}

function Send-Once([string]$Method, [string]$Uri, [byte[]]$Body, [string]$ProxyUrl) {
  $cfg = Get-Cfg
  $req = [System.Net.HttpWebRequest]::Create($Uri)
  $req.Method = $Method
  $req.Accept = 'application/json'
  $req.Timeout = 60000
  $req.ReadWriteTimeout = 60000
  $req.Headers.Add('PRIVATE-TOKEN', $cfg.Token)
  if ($ProxyUrl) { $req.Proxy = New-Object System.Net.WebProxy($ProxyUrl) }
  $resp = $null
  try {
    if ($null -ne $Body) {
      $req.ContentType = 'application/json; charset=utf-8'
      $req.ContentLength = $Body.Length
      $stream = $req.GetRequestStream()
      try { $stream.Write($Body, 0, $Body.Length) } finally { $stream.Close() }
    }
    $resp = $req.GetResponse()
  } catch {
    $we = Get-WebException $_
    if ($we -and $we.Response) { $resp = $we.Response }
    elseif ($we) { return @{ Transport = $true; Reason = $we.Status.ToString() } }
    else { throw }
  }
  try {
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), $Utf8)
    $text = $reader.ReadToEnd()
    @{ Transport = $false; Status = [int]$resp.StatusCode; Text = $text; NextPage = $resp.Headers['X-Next-Page'] }
  } finally {
    $resp.Close()
  }
}

# A POST that timed out may already have reached the server, so only connect-stage failures are retried.
$ConnectFailures = @('ConnectFailure', 'NameResolutionFailure', 'SecureChannelFailure', 'TrustFailure', 'ProxyNameResolutionFailure')

function Invoke-GitLab([string]$Method, [string]$Path, $Payload) {
  $cfg = Get-Cfg
  $uri = $cfg.Url + $Path
  $body = $null
  if ($null -ne $Payload) { $body = $Utf8.GetBytes(($Payload | ConvertTo-Json -Depth 30 -Compress)) }
  $r = Send-Once $Method $uri $body $null
  if ($r.Transport) {
    $retryable = ($Method -eq 'GET') -or ($ConnectFailures -contains $r.Reason)
    if (-not $cfg.Proxy -or -not $retryable) { throw "transport failure ($($r.Reason)) on $Method $Path" }
    Write-Note "direct connection failed ($($r.Reason)); retrying once through HTTP_PROXY_URL"
    $r = Send-Once $Method $uri $body $cfg.Proxy
    if ($r.Transport) { throw "transport failure through proxy ($($r.Reason)) on $Method $Path" }
  }
  if ($r.Status -lt 200 -or $r.Status -ge 300) {
    $snippet = $r.Text
    if ($snippet -and $snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
    throw "HTTP $($r.Status) on $Method $Path : $snippet"
  }
  $r
}

# PowerShell 5.1 ConvertFrom-Json emits a JSON array as one object; re-enumerate it.
function ConvertFrom-JsonArray([string]$Text) {
  $parsed = $Text | ConvertFrom-Json
  , @($parsed | ForEach-Object { $_ })
}

function Invoke-Gql([string]$Query, $Variables) {
  if ($null -eq $Variables) { $Variables = @{} }
  $r = Invoke-GitLab 'POST' '/api/graphql' @{ query = $Query; variables = $Variables }
  $data = $r.Text | ConvertFrom-Json
  if ($data.errors) { throw ('GraphQL error: ' + (($data.errors | ForEach-Object { $_.message }) -join '; ')) }
  $data.data
}

$script:ProjectIds = @{}
function Get-ProjectGid([string]$FullPath) {
  if (-not $script:ProjectIds.ContainsKey($FullPath)) {
    $d = Invoke-Gql 'query($p: ID!) { project(fullPath: $p) { id } }' @{ p = $FullPath }
    if (-not $d.project) { throw "project not found or not visible: $FullPath" }
    $script:ProjectIds[$FullPath] = $d.project.id
  }
  $script:ProjectIds[$FullPath]
}

function Get-ProjectApiId([string]$FullPath) {
  (Get-ProjectGid $FullPath) -replace '^gid://gitlab/Project/', ''
}

function Get-TasksProjectId {
  $p = $Project
  if (-not $p) { $p = (Get-Cfg).Tasks }
  Get-ProjectApiId $p
}

function Get-WikiPageNode([string]$PageSlug) {
  $q = 'query($slug: String!, $projectId: ProjectID!) { wikiPage(slug: $slug, projectId: $projectId) { id title } }'
  $d = Invoke-Gql $q @{ slug = $PageSlug; projectId = (Get-ProjectGid $WikiProject) }
  if (-not $d.wikiPage) { throw "wiki page not found: $PageSlug" }
  $d.wikiPage
}

function Get-NoteNode([string]$Gid) {
  $d = Invoke-Gql 'query($id: NoteID!) { note(id: $id) { id body createdAt author { username } } }' @{ id = $Gid }
  if (-not $d.note) { throw "note not found: $Gid" }
  $d.note
}

function Get-AllPages([string]$Path) {
  $items = @()
  $page = 1
  while ($true) {
    $sep = '?'
    if ($Path.Contains('?')) { $sep = '&' }
    $r = Invoke-GitLab 'GET' "$Path$($sep)per_page=100&page=$page" $null
    $items += ConvertFrom-JsonArray $r.Text
    if (-not $r.NextPage) { break }
    $page = [int]$r.NextPage
  }
  , $items
}

# ---------------------------------------------------------------- git (wiki-ro)

function Invoke-Git([string[]]$GitArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & git @GitArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
  @{ Code = $code; Text = (@($output) -join "`n") }
}

function Get-WikiGitArgs {
  if (-not (Test-Path -LiteralPath $WikiClone)) { throw "wiki clone not found: $WikiClone" }
  @('-C', $WikiClone, '-c', "safe.directory=$($WikiClone.Replace('\', '/'))", '-c', 'core.quotepath=false')
}

function Test-TransportText([string]$Text) {
  $Text -match '(?i)could not resolve|failed to connect|connection (timed out|reset|refused)|unable to access|recv failure|ssl|tls|schannel|timed out'
}

function Invoke-GitNetwork([string[]]$GitArgs) {
  $base = (Get-WikiGitArgs) + @('-c', 'http.sslBackend=openssl')
  $r = Invoke-Git ($base + $GitArgs)
  if ($r.Code -ne 0 -and (Test-TransportText $r.Text)) {
    $proxy = (Read-DotEnv)['HTTP_PROXY_URL']
    if ($proxy) {
      Write-Note 'git transport failed; retrying once through HTTP_PROXY_URL'
      $r = Invoke-Git ($base + @('-c', "http.proxy=$proxy") + $GitArgs)
    }
  }
  $r
}

function Get-LastLines([string]$Text, [int]$Count) {
  $lines = @($Text -split "`n" | Where-Object { $_.Trim() })
  if ($lines.Count -le $Count) { return ($lines -join "`n") }
  $lines[($lines.Count - $Count)..($lines.Count - 1)] -join "`n"
}

function Get-WikiFileRef([string]$PageSlug) {
  $file = "$PageSlug.md"
  $refs = @($Ref)
  if ($Ref -eq 'HEAD') { $refs += 'origin/main' }
  foreach ($candidate in $refs) {
    $c = Invoke-Git ((Get-WikiGitArgs) + @('cat-file', '-e', ($candidate + ':' + $file)))
    if ($c.Code -eq 0) { return @{ Ref = $candidate; File = $file } }
  }
  throw "page file not in wiki-ro ($($refs -join ', ')): $file. Run wiki-refresh or check the slug."
}

# ---------------------------------------------------------------- commands

function Show-Help {
  @'
Usage: powershell -NoProfile -File tools\gitlab.ps1 <command> [options]
Full guide: docs/agent/gitlab-tool.md

Wiki (project superuni/development/analyze/dormitory-bpms)
  wiki-refresh                                   pull wiki-ro (ff-only, proxy retry, fetch fallback)
  wiki-version     -Slug <url|slug> [-Ref r]     user-story version vN from wiki-ro history
  wiki-page        -Slug <url|slug> [-Ref r] [-Remote] [-Out f]
  wiki-update      -Slug <url|slug> -BodyFile f (-DryRun | -Approved)
  catalog-status   -Slug <catalog url> [-Out page.md]
  wiki-notes       -Slug <url|slug> [-IncludeSystem] [-Out f]
  wiki-note        -NoteId <n|gid|url#note_n>
  wiki-post        -Slug <url|slug> -BodyFile f [-DiscussionId d] (-DryRun | -Approved)
  wiki-note-update -NoteId <id> -BodyFile f (-DryRun | -Approved)
  wiki-note-delete -NoteId <id> (-DryRun | -Approved)
  wiki-file        -Slug <uploads/hash/file or full URL> -Out f

Issues (default project: GITLAB_TASKS_PROJECT, override with -Project)
  labels           [-Search text]
  issue-search     -Search text [-State all|opened|closed]
  issue-get        -Iid n [-Notes] [-IncludeSystem] [-Out f]
  issue-create     -Title t -BodyFile f -Labels "a,b" [-Assignee user] (-DryRun | -Approved)
  issue-note       -Iid n -BodyFile f (-DryRun | -Approved)
  issue-delete     -Iid n (-DryRun | -Approved)

Raw (only when no command above fits)
  rest-get         -ApiPath /api/v4/... [-Out f]
  graphql          -QueryFile f [-VariablesJson '{...}'] [-Approved for mutations] [-Out f]
'@
}

function Invoke-WikiRefresh {
  $r = Invoke-GitNetwork @('pull', '--ff-only', '--quiet')
  if ($r.Code -ne 0) {
    Write-Note ('pull failed: ' + (Get-LastLines $r.Text 3))
    $f = Invoke-GitNetwork @('fetch', '--quiet', 'origin')
    if ($f.Code -ne 0) { throw ('wiki fetch failed: ' + (Get-LastLines $f.Text 3)) }
    $o = Invoke-Git ((Get-WikiGitArgs) + @('log', '-1', '--format=%h %ci', 'origin/main'))
    Write-Output "fetched only; read pages with -Ref origin/main (origin/main $($o.Text))"
    return
  }
  $h = Invoke-Git ((Get-WikiGitArgs) + @('log', '-1', '--format=%h %ci', 'HEAD'))
  Write-Output "wiki-ro up to date at HEAD $($h.Text)"
}

function Invoke-WikiVersion {
  $pageSlug = ConvertTo-Slug $Slug
  $loc = Get-WikiFileRef $pageSlug
  $r = Invoke-Git ((Get-WikiGitArgs) + @('rev-list', '--count', $loc.Ref, '--', $loc.File))
  if ($r.Code -ne 0) { throw ('rev-list failed: ' + (Get-LastLines $r.Text 3)) }
  Write-Output "v$($r.Text.Trim()) (ref=$($loc.Ref), file=$($loc.File))"
}

function Invoke-WikiPage {
  $pageSlug = ConvertTo-Slug $Slug
  if ($Remote) {
    $projId = Get-ProjectApiId $WikiProject
    $r = Invoke-GitLab 'GET' "/api/v4/projects/$projId/wikis/$([Uri]::EscapeDataString($pageSlug))" $null
    Write-Result ($r.Text | ConvertFrom-Json).content
    return
  }
  $loc = Get-WikiFileRef $pageSlug
  $r = Invoke-Git ((Get-WikiGitArgs) + @('show', ($loc.Ref + ':' + $loc.File)))
  if ($r.Code -ne 0) { throw ('git show failed: ' + (Get-LastLines $r.Text 3)) }
  Write-Note "source: wiki-ro $($loc.Ref):$($loc.File)"
  Write-Result $r.Text
}

function Invoke-WikiUpdate {
  $body = Read-BodyFile
  $pageSlug = ConvertTo-Slug $Slug
  $projId = Get-ProjectApiId $WikiProject
  $enc = [Uri]::EscapeDataString($pageSlug)
  $path = "/api/v4/projects/$projId/wikis/$enc"
  $current = (Invoke-GitLab 'GET' $path $null).Text | ConvertFrom-Json
  if ($DryRun) {
    Write-Output "dry-run: would replace wiki '$($current.title)' ($pageSlug) with $($body.Length) chars"
    return
  }
  Assert-Approved 'wiki-update'
  [void](Invoke-GitLab 'PUT' $path @{ title = [string]$current.title; content = $body; format = 'markdown' })
  $again = (Invoke-GitLab 'GET' $path $null).Text | ConvertFrom-Json
  Write-Output "updated $(Get-WikiPageUrl $pageSlug)"
  if ((Normalize-Text $again.content) -eq (Normalize-Text $body)) {
    Write-Output 're-read: content matches'
  } else {
    Write-Output 're-read: CONTENT MISMATCH - compare the page with the body file'
    exit 2
  }
}

function Import-CatalogLexicon {
  $path = Join-Path $PSScriptRoot 'catalog-status-lexicon.txt'
  if (-not (Test-Path -LiteralPath $path)) { throw "missing $path" }
  $enc = New-Object System.Text.UTF8Encoding $false
  $map = @{}
  foreach ($line in [IO.File]::ReadAllLines($path, $enc)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1)
  }
  foreach ($k in @('story_header','api_header','status_prefix','similar','has_api','mark_ok','mark_warn','mark_bad','qa','backend')) {
    if (-not $map.ContainsKey($k) -or -not $map[$k]) { throw "lexicon missing $k" }
  }
  $script:Lex = $map
}

function Test-LexContains([string]$Text, [string[]]$Keys) {
  foreach ($k in $Keys) {
    $needle = $script:Lex[$k]
    if ($needle -and $Text.Contains($needle)) { return $true }
  }
  $false
}

function Get-CatalogMark([string]$Line) {
  $badShort = @('short_bad','short_badge','short_stop')
  foreach ($k in $badShort) {
    if ($Line.Contains($script:Lex[$k])) { return $script:Lex.mark_bad }
  }
  if ($Line.Contains($script:Lex.mark_bad)) { return $script:Lex.mark_bad }
  if ((Test-LexContains $Line @('needle_cannot','needle_cannot2','needle_problem'))) { return $script:Lex.mark_bad }
  if ($Line.Contains($script:Lex.short_warn) -or $Line.Contains($script:Lex.mark_warn)) { return $script:Lex.mark_warn }
  if ($Line.Contains($script:Lex.short_ok) -or $Line.Contains($script:Lex.mark_ok)) { return $script:Lex.mark_ok }
  if ($Line.Contains($script:Lex.needle_note)) { return $script:Lex.mark_warn }
  if ((Test-LexContains $Line @('needle_fine','needle_ready','needle_ready_for'))) { return $script:Lex.mark_ok }
  ''
}

function Convert-CatalogCell([string]$Raw) {
  $t = $Raw.Trim()
  if ($t -eq $script:Lex.short_ok) { return $script:Lex.mark_ok }
  if ($t -eq $script:Lex.short_warn) { return $script:Lex.mark_warn }
  if ($t -eq $script:Lex.short_bad -or $t -eq $script:Lex.short_badge -or $t -eq $script:Lex.short_stop) { return $script:Lex.mark_bad }
  $t
}

function Get-CellWikiUrl([string]$Cell) {
  $m = [regex]::Match($Cell, '\]\((https:(?:\\\)|[^\s)])+)\)')
  if ($m.Success) { return $m.Groups[1].Value.Replace('\)', ')') }
  $b = [regex]::Match($Cell, 'https://[^\s<>"]+')
  if (-not $b.Success) { return $null }
  $b.Value.TrimEnd(')', '.', ',')
}

function Test-TableSep([string]$Line) {
  $any = $false
  foreach ($c in $Line.Split('|')) {
    $t = $c.Trim()
    if ($t -eq '') { continue }
    $any = $true
    if ($t -notmatch '^:?-+:?$') { return $false }
  }
  $any
}

function Get-RemoteWikiContent([string]$PageSlug) {
  $projId = Get-ProjectApiId $WikiProject
  $enc = [Uri]::EscapeDataString($PageSlug)
  $obj = (Invoke-GitLab 'GET' "/api/v4/projects/$projId/wikis/$enc" $null).Text | ConvertFrom-Json
  [string]$obj.content
}

function Get-WikiNoteNodes([string]$PageSlug) {
  $q = @'
query($slug: String!, $projectId: ProjectID!, $after: String) {
  wikiPage(slug: $slug, projectId: $projectId) {
    id
    discussions(first: 50, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id
        notes(first: 100) {
          pageInfo { hasNextPage }
          nodes { id body createdAt system author { username } }
        }
      }
    }
  }
}
'@
  $gid = Get-ProjectGid $WikiProject
  $after = $null
  $notes = New-Object System.Collections.Generic.List[object]
  do {
    $d = Invoke-Gql $q @{ slug = $PageSlug; projectId = $gid; after = $after }
    if (-not $d.wikiPage) { throw "wiki page not found: $PageSlug" }
    foreach ($disc in @($d.wikiPage.discussions.nodes)) {
      if ($disc.notes.pageInfo.hasNextPage) { Write-Note "thread $($disc.id) has more than 100 notes; only the first 100 are used" }
      foreach ($n in @($disc.notes.nodes)) {
        if ($n.system) { continue }
        $notes.Add([pscustomobject]@{
          Author = [string]$n.author.username
          When   = [string]$n.createdAt
          Thread = [string]$disc.id
          Body   = Normalize-Text ([string]$n.body)
        })
      }
    }
    $info = $d.wikiPage.discussions.pageInfo
    $after = $info.endCursor
  } while ($info.hasNextPage)
  ,$notes.ToArray()
}

function Get-WorseCatalogMark([string]$Left, [string]$Right) {
  if (-not $Left) { return $Right }
  if (-not $Right) { return $Left }
  $rank = @{
    $script:Lex.mark_ok   = 1
    $script:Lex.mark_warn = 2
    $script:Lex.mark_bad  = 3
  }
  if ($rank[$Left] -ge $rank[$Right]) { return $Left }
  return $Right
}

function Get-CatalogEndpointKey([string]$Body) {
  $methods = [regex]::Matches($Body, '(?im)^\s*[-*]?\s*\[[xX]\]\s*(GET|POST|PUT|PATCH|DELETE)\b')
  $method = ''
  if ($methods.Count -gt 0) {
    $method = (($methods | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Sort-Object) -join '+')
  } else {
    $one = [regex]::Match($Body, '(?im)^\s*[-*]?\s*Method:\s*(GET|POST|PUT|PATCH|DELETE)\b')
    if ($one.Success) { $method = $one.Groups[1].Value.ToUpperInvariant() }
  }
  $pathMatch = [regex]::Match($Body, '(?im)Path:\s*`?((?:https?://[^\s`]+)?/api/v1/[^\s`]+)')
  if (-not $method -or -not $pathMatch.Success) { return '' }
  $raw = $pathMatch.Groups[1].Value.TrimEnd(')', '.', ',')
  $at = $raw.IndexOf('/api/v1/')
  if ($at -lt 0) { return '' }
  $path = ($raw.Substring($at) -split '[?#]')[0].TrimEnd('/')
  if (-not $path) { return '' }
  "$method $path"
}

function Get-CatalogStatusFromNotes($Notes) {
  $qa = @($script:Lex.qa.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $be = @($script:Lex.backend.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $story = $null
  $apiNotes = New-Object System.Collections.Generic.List[object]
  $hasBe = $false
  $similarNote = $false
  $unclassified = 0
  foreach ($n in @($Notes)) {
    $isBe = $be -contains $n.Author
    if ($isBe) {
      $method = $n.Body -match '(?m)(^|[^A-Za-z])(GET|POST|PUT|PATCH|DELETE)([^A-Za-z]|$)'
      $path = $n.Body -match 'https?://|/api/v1/'
      if ($method -and $path) { $hasBe = $true }
    }
    if ($qa -notcontains $n.Author) { continue }
    $statusLine = ''
    foreach ($bline in ($n.Body -split "`n")) {
      $trim = $bline.Trim()
      if ($trim.StartsWith($script:Lex.status_prefix)) { $statusLine = $trim; break }
    }
    if (-not $statusLine) {
      $bare = [regex]::Replace($n.Body, 'https?://\S+', ' ')
      $words = @($bare -split '\s+' | Where-Object { $_ })
      if (($words -join ' ') -eq $script:Lex.similar) { $similarNote = $true }
      continue
    }
    $mark = Get-CatalogMark $statusLine
    if (-not $mark) { $unclassified++; continue }
    $isApi = (Test-LexContains $statusLine @('needle_front','needle_connect','needle_impl')) -or (Test-LexContains $n.Body @('needle_api','needle_api_doc'))
    $isStory = (Test-LexContains $statusLine @('needle_backend','needle_backend2','needle_prep')) -or (Test-LexContains $n.Body @('needle_story'))
    if ($isApi) {
      $thread = $n.Thread
      if (-not $thread) { $thread = $n.When }
      $apiNotes.Add([pscustomobject]@{
        Mark     = $mark
        When     = $n.When
        Thread   = $thread
        Endpoint = (Get-CatalogEndpointKey $n.Body)
      })
    } elseif ($isStory) {
      if (-not $story -or $n.When -gt $story.When) { $story = @{ Mark = $mark; When = $n.When } }
    } else {
      $unclassified++
    }
  }
  $byThread = @{}
  foreach ($a in $apiNotes) {
    $prev = $byThread[$a.Thread]
    if (-not $prev -or $a.When -gt $prev.When) { $byThread[$a.Thread] = $a }
  }
  $byApi = @{}
  foreach ($a in $byThread.Values) {
    $key = $a.Endpoint
    if (-not $key) { $key = 'thread:' + $a.Thread }
    $prev = $byApi[$key]
    if (-not $prev -or $a.When -gt $prev.When) { $byApi[$key] = $a }
  }
  $storyCell = ''
  $apiCell = ''
  if ($story) { $storyCell = $story.Mark }
  foreach ($a in $byApi.Values) {
    $apiCell = Get-WorseCatalogMark $apiCell $a.Mark
  }
  if (-not $apiCell -and $hasBe) { $apiCell = $script:Lex.has_api }
  @{ Story = $storyCell; Api = $apiCell; SimilarNote = $similarNote; Unclassified = $unclassified }
}

function Resolve-CatalogCells([string]$Code, [string]$Url, [string]$RawStory, [string]$RawApi) {
  $oldStory = Convert-CatalogCell $RawStory
  $oldApi = Convert-CatalogCell $RawApi
  try {
    $got = Get-CatalogStatusFromNotes (Get-WikiNoteNodes (ConvertTo-Slug $Url))
  } catch {
    return @{ Failed = $true; Error = $_.Exception.Message; Code = $Code }
  }
  $storyCell = [string]$got.Story
  $apiCell = [string]$got.Api
  if ($oldStory -eq $script:Lex.similar) { $storyCell = $script:Lex.similar }
  elseif (-not $storyCell -and $got.SimilarNote) { $storyCell = $script:Lex.similar }
  if ($oldApi -eq $script:Lex.similar) { $apiCell = $script:Lex.similar }
  $rawStoryTrim = $RawStory.Trim()
  $rawApiTrim = $RawApi.Trim()
  @{
    Failed       = $false
    Code         = $Code
    Unclassified = [int]$got.Unclassified
    Logic        = (($oldStory -ne $storyCell) -or ($oldApi -ne $apiCell))
    Form         = (($rawStoryTrim -ne $storyCell) -or ($rawApiTrim -ne $apiCell))
    Story        = $storyCell
    Api          = $apiCell
    RawStory     = $rawStoryTrim
    RawApi       = $rawApiTrim
  }
}

function Add-CatalogChange($Changes, $Result) {
  $flag = 'NORM'
  if ($Result.Logic) { $flag = 'CHG' }
  $Changes.Add("$flag`t$($Result.Code)`t$($Result.RawStory)`t$($Result.Story)`t$($Result.RawApi)`t$($Result.Api)")
}

function Get-HtmlCellInner([string]$Cell) {
  $m = [regex]::Match($Cell, '(?s)^<(?:th|td)\b[^>]*>(.*)</(?:th|td)>$')
  if (-not $m.Success) { return '' }
  $m.Groups[1].Value
}

function Set-HtmlCellInner([string]$Cell, [string]$Inner) {
  $m = [regex]::Match($Cell, '(?s)^(<(?:th|td)\b[^>]*>)(.*)(</(?:th|td)>)$')
  if (-not $m.Success) { return $Cell }
  $m.Groups[1].Value + $Inner + $m.Groups[3].Value
}

function Update-OneHtmlCatalogTable([string]$Table, $Changes) {
  $rowRx = [regex]::new('(?si)<tr\b[^>]*>.*?</tr>')
  $cellRx = [regex]::new('(?si)<(th|td)\b[^>]*>.*?</\1>')
  $storyCol = -1
  $apiCol = -1
  $rows = 0
  $changed = 0
  $normalized = 0
  $failed = 0
  $unclassified = 0
  $seen = 0
  $sb = New-Object System.Text.StringBuilder
  $pos = 0
  foreach ($rm in $rowRx.Matches($Table)) {
    [void]$sb.Append($Table.Substring($pos, $rm.Index - $pos))
    $row = $rm.Value
    $pos = $rm.Index + $rm.Length
    $cellMatches = @($cellRx.Matches($row))
    if ($cellMatches.Count -eq 0) { [void]$sb.Append($row); continue }
    $inners = New-Object System.Collections.Generic.List[string]
    foreach ($cell in $cellMatches) { $inners.Add((Get-HtmlCellInner $cell.Value)) }
    $headerStory = -1
    $headerApi = -1
    for ($i = 0; $i -lt $inners.Count; $i++) {
      $name = $inners[$i].Trim()
      if ($name -eq $script:Lex.story_header) { $headerStory = $i }
      if ($name -eq $script:Lex.api_header) { $headerApi = $i }
    }
    if ($headerStory -ge 0 -and $headerApi -ge 0) {
      $storyCol = $headerStory
      $apiCol = $headerApi
      [void]$sb.Append($row)
      continue
    }
    if ($storyCol -lt 0 -or $storyCol -ge $inners.Count -or $apiCol -ge $inners.Count) {
      [void]$sb.Append($row)
      continue
    }
    $url = $null
    foreach ($inner in $inners) {
      $url = Get-CellWikiUrl $inner
      if ($url) { break }
    }
    if (-not $url) { [void]$sb.Append($row); continue }
    $code = $inners[0].Trim()
    if (-not $code) { $code = $url }
    $rows = $rows + 1
    $seen = $seen + 1
    if (($seen % 25) -eq 0) { Write-Note "catalog-status $seen stories" }
    $result = Resolve-CatalogCells $code $url $inners[$storyCol] $inners[$apiCol]
    if ($result.Failed) {
      $failed = $failed + 1
      Write-Note "FAIL $code $($result.Error)"
      [void]$sb.Append($row)
      continue
    }
    $unclassified = $unclassified + $result.Unclassified
    if ($result.Logic) { $changed = $changed + 1 } elseif ($result.Form) { $normalized = $normalized + 1 }
    if ($result.Logic -or $result.Form) {
      Add-CatalogChange $Changes $result
      $newByCol = @{ $storyCol = [string]$result.Story; $apiCol = [string]$result.Api }
      foreach ($idx in (@($storyCol, $apiCol) | Sort-Object -Descending)) {
        if ($inners[$idx].Trim() -eq $newByCol[$idx]) { continue }
        $cur = $cellMatches[$idx]
        $updated = Set-HtmlCellInner $cur.Value $newByCol[$idx]
        $row = $row.Substring(0, $cur.Index) + $updated + $row.Substring($cur.Index + $cur.Length)
      }
    }
    [void]$sb.Append($row)
  }
  [void]$sb.Append($Table.Substring($pos))
  [pscustomobject]@{
    Text         = $sb.ToString()
    Rows         = $rows
    Changed      = $changed
    Normalized   = $normalized
    Failed       = $failed
    Unclassified = $unclassified
  }
}

function Update-HtmlCatalogText([string]$Text, $Changes) {
  $tableRx = [regex]::new('(?si)<table\b[^>]*>.*?</table>')
  $rows = 0
  $changed = 0
  $normalized = 0
  $failed = 0
  $unclassified = 0
  $sb = New-Object System.Text.StringBuilder
  $pos = 0
  foreach ($tm in $tableRx.Matches($Text)) {
    [void]$sb.Append($Text.Substring($pos, $tm.Index - $pos))
    $one = Update-OneHtmlCatalogTable $tm.Value $Changes
    [void]$sb.Append($one.Text)
    $rows = $rows + $one.Rows
    $changed = $changed + $one.Changed
    $normalized = $normalized + $one.Normalized
    $failed = $failed + $one.Failed
    $unclassified = $unclassified + $one.Unclassified
    $pos = $tm.Index + $tm.Length
  }
  [void]$sb.Append($Text.Substring($pos))
  [pscustomobject]@{
    Text         = $sb.ToString()
    Rows         = $rows
    Changed      = $changed
    Normalized   = $normalized
    Failed       = $failed
    Unclassified = $unclassified
  }
}

function Invoke-CatalogStatus {
  if (-not $Slug) { throw '-Slug is required (catalog wiki URL)' }
  Import-CatalogLexicon
  $pageSlug = ConvertTo-Slug $Slug
  $raw = (Get-RemoteWikiContent $pageSlug).Replace("`r`n", "`n")
  $ends = $raw.EndsWith("`n")
  $lines = $raw.TrimEnd("`n") -split "`n", -1
  $storyCol = -1
  $apiCol = -1
  $inTable = $false
  $pageLines = New-Object System.Collections.Generic.List[string]
  $changes = New-Object System.Collections.Generic.List[string]
  $rows = 0
  $changed = 0
  $normalized = 0
  $failed = 0
  $unclassified = 0
  $seen = 0
  foreach ($line in $lines) {
    if ($line -notmatch '^\|') { $inTable = $false; $pageLines.Add($line); continue }
    $cells = @($line.Split('|'))
    $headerStory = -1
    $headerApi = -1
    for ($i = 0; $i -lt $cells.Count; $i++) {
      $name = $cells[$i].Trim()
      if ($name -eq $script:Lex.story_header) { $headerStory = $i }
      if ($name -eq $script:Lex.api_header) { $headerApi = $i }
    }
    if ($headerStory -ge 0 -and $headerApi -ge 0) {
      $inTable = $true
      $storyCol = $headerStory
      $apiCol = $headerApi
      $pageLines.Add($line)
      continue
    }
    if (-not $inTable -or (Test-TableSep $line)) { $pageLines.Add($line); continue }
    $url = $null
    foreach ($c in $cells) {
      $url = Get-CellWikiUrl $c
      if ($url) { break }
    }
    if (-not $url) { $pageLines.Add($line); continue }
    $rows++
    $seen++
    $code = $cells[1].Trim()
    if (-not $code) { $code = $url }
    if (($seen % 25) -eq 0) { Write-Note "catalog-status $seen stories" }
    $result = Resolve-CatalogCells $code $url $cells[$storyCol] $cells[$apiCol]
    if ($result.Failed) {
      $failed++
      Write-Note "FAIL $code $($result.Error)"
      $pageLines.Add($line)
      continue
    }
    $unclassified += $result.Unclassified
    if ($result.Logic) { $changed++ } elseif ($result.Form) { $normalized++ }
    if ($result.Logic -or $result.Form) {
      Add-CatalogChange $changes $result
      if ($result.Story) { $cells[$storyCol] = " $($result.Story) " } else { $cells[$storyCol] = ' ' }
      if ($result.Api) { $cells[$apiCol] = " $($result.Api) " } else { $cells[$apiCol] = ' ' }
      $line = $cells -join '|'
    }
    $pageLines.Add($line)
  }
  $text = ($pageLines -join "`n")
  if ($ends) { $text += "`n" }
  $html = Update-HtmlCatalogText $text $changes
  $text = $html.Text
  $rows += $html.Rows
  $changed += $html.Changed
  $normalized += $html.Normalized
  $failed += $html.Failed
  $unclassified += $html.Unclassified
  if ($rows -eq 0) { throw 'no catalog data rows with a wiki link under the status columns' }
  $pageFile = Join-Path $RepoRoot '.tmp\catalog-status\page.md'
  if ($Out) { $pageFile = Resolve-UserPath $Out }
  $dir = Split-Path -Parent $pageFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $enc = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText($pageFile, $text, $enc)
  $changeFile = Join-Path $dir 'changes.tsv'
  [IO.File]::WriteAllLines($changeFile, $changes.ToArray(), $enc)
  $diff = 'no'
  if ((Normalize-Text $text) -ne (Normalize-Text $raw)) { $diff = 'yes' }
  Write-Output "rows=$rows changed=$changed normalized=$normalized failed=$failed unclassified=$unclassified page-diff=$diff"
  Write-Output "page=$pageFile"
  Write-Output "changes=$changeFile"
  foreach ($row in $changes) {
    if ($row.StartsWith('CHG')) { Write-Output $row }
  }
  if ($failed -gt 0) { throw "$failed story note fetches failed; do not wiki-update" }
}

function Invoke-WikiNotes {
  $pageSlug = ConvertTo-Slug $Slug
  $q = @'
query($slug: String!, $projectId: ProjectID!, $after: String) {
  wikiPage(slug: $slug, projectId: $projectId) {
    id
    discussions(first: 50, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id
        notes(first: 100) {
          pageInfo { hasNextPage }
          nodes { id body createdAt system author { username } }
        }
      }
    }
  }
}
'@
  $gid = Get-ProjectGid $WikiProject
  $after = $null
  $pageId = $null
  $blocks = New-Object System.Collections.Generic.List[string]
  $count = 0
  $hidden = 0
  do {
    $d = Invoke-Gql $q @{ slug = $pageSlug; projectId = $gid; after = $after }
    if (-not $d.wikiPage) { throw "wiki page not found: $pageSlug" }
    $pageId = $d.wikiPage.id
    foreach ($disc in @($d.wikiPage.discussions.nodes)) {
      if ($disc.notes.pageInfo.hasNextPage) { Write-Note "thread $($disc.id) has more than 100 notes; only the first 100 are shown" }
      foreach ($n in @($disc.notes.nodes)) {
        if ($n.system -and -not $IncludeSystem) { $hidden++; continue }
        $count++
        $num = $n.id -replace '^gid://gitlab/Note/', ''
        $thread = $disc.id -replace '^gid://gitlab/Discussion/', ''
        $blocks.Add("=== #note_$num | $($n.author.username) | $($n.createdAt) | thread $thread ===`n$(Normalize-Text $n.body)")
      }
    }
    $info = $d.wikiPage.discussions.pageInfo
    $after = $info.endCursor
  } while ($info.hasNextPage)
  $header = "page: $(Get-WikiPageUrl $pageSlug)`nwikiPage: $pageId`nnotes: $count (system hidden: $hidden)"
  Write-Result (($header, ($blocks -join "`n`n")) -join "`n`n").TrimEnd()
}

function Invoke-WikiNote {
  $n = Get-NoteNode (ConvertTo-NoteGid $NoteId)
  Write-Result "=== $($n.id) | $($n.author.username) | $($n.createdAt) ===`n$(Normalize-Text $n.body)"
}

function Confirm-NoteBody([string]$Gid, [string]$Expected) {
  $actual = Normalize-Text (Get-NoteNode $Gid).body
  $actual -eq (Normalize-Text $Expected)
}

function Invoke-WikiPost {
  $body = Read-BodyFile
  $pageSlug = ConvertTo-Slug $Slug
  $page = Get-WikiPageNode $pageSlug
  $discussion = ConvertTo-DiscussionGid $DiscussionId
  $firstLine = ($body -split "`n")[0]
  if ($DryRun) {
    Write-Output "dry-run: would post $($body.Length) chars to $($page.id) ($($page.title))"
    if ($discussion) { Write-Output "as a reply in $discussion" }
    Write-Output "first line: $firstLine"
    return
  }
  Assert-Approved 'wiki-post'
  $noteInput = @{ noteableId = $page.id; body = $body }
  if ($discussion) { $noteInput.discussionId = $discussion }
  $m = 'mutation($input: CreateNoteInput!) { createNote(input: $input) { note { id url } errors } }'
  $res = (Invoke-Gql $m @{ input = $noteInput }).createNote
  if (@($res.errors).Count -gt 0) { throw ('createNote errors: ' + ($res.errors -join '; ')) }
  if (-not $res.note) { throw 'createNote returned no note' }
  Write-Output "posted $($res.note.url)"
  if (Confirm-NoteBody $res.note.id $body) {
    Write-Output 're-read: body matches the approved draft'
  } else {
    Write-Output 're-read: BODY MISMATCH - open the note and compare with the draft'
    exit 2
  }
}

function Invoke-WikiNoteUpdate {
  $gid = ConvertTo-NoteGid $NoteId
  $body = Read-BodyFile
  $current = Get-NoteNode $gid
  if ($DryRun) {
    Write-Output "dry-run: would replace $gid (author $($current.author.username), $((Normalize-Text $current.body).Length) chars) with $($body.Length) chars"
    return
  }
  Assert-Approved 'wiki-note-update'
  $m = 'mutation($input: UpdateNoteInput!) { updateNote(input: $input) { note { id } errors } }'
  $res = (Invoke-Gql $m @{ input = @{ id = $gid; body = $body } }).updateNote
  if (@($res.errors).Count -gt 0) { throw ('updateNote errors: ' + ($res.errors -join '; ')) }
  Write-Output "updated $gid"
  if (Confirm-NoteBody $gid $body) {
    Write-Output 're-read: body matches the approved draft'
  } else {
    Write-Output 're-read: BODY MISMATCH - open the note and compare with the draft'
    exit 2
  }
}

function Invoke-WikiNoteDelete {
  $gid = ConvertTo-NoteGid $NoteId
  $current = Get-NoteNode $gid
  if ($DryRun) {
    Write-Output "dry-run: would delete $gid (author $($current.author.username), $((Normalize-Text $current.body).Length) chars)"
    Write-Output "first line: $(((Normalize-Text $current.body) -split "`n")[0])"
    return
  }
  Assert-Approved 'wiki-note-delete'
  $m = 'mutation($input: DestroyNoteInput!) { destroyNote(input: $input) { note { id } errors } }'
  $res = (Invoke-Gql $m @{ input = @{ id = $gid } }).destroyNote
  if (@($res.errors).Count -gt 0) { throw ('destroyNote errors: ' + ($res.errors -join '; ')) }
  Write-Output "deleted $gid"
}

function Invoke-Labels {
  $projId = Get-TasksProjectId
  $path = "/api/v4/projects/$projId/labels?include_ancestor_groups=true"
  if ($Search) { $path += '&search=' + [Uri]::EscapeDataString($Search) }
  $items = Get-AllPages $path
  $lines = foreach ($l in $items) {
    $mark = ''
    if ($ForbiddenLabels -contains $l.name) { $mark = '   <- forbidden' }
    "$($l.name)$mark"
  }
  Write-Result ((@("labels: $(@($items).Count)") + @($lines | Sort-Object)) -join "`n")
}

function Format-Issue($It) {
  "#$($It.iid) [$($It.state)] $($It.title)`n    labels: $((@($It.labels)) -join ', ') | $($It.web_url)"
}

function Invoke-IssueSearch {
  if (-not $Search) { throw '-Search is required' }
  $projId = Get-TasksProjectId
  $path = "/api/v4/projects/$projId/issues?scope=all&state=$State&in=title,description&per_page=100&search=" + [Uri]::EscapeDataString($Search)
  $r = Invoke-GitLab 'GET' $path $null
  $items = ConvertFrom-JsonArray $r.Text
  $lines = @("issues matching '$Search' (state=$State): $($items.Count)")
  foreach ($it in $items) { $lines += (Format-Issue $it) }
  if ($r.NextPage) { $lines += 'more than 100 results; narrow -Search' }
  Write-Result ($lines -join "`n")
}

function Invoke-IssueGet {
  if (-not $Iid) { throw '-Iid is required' }
  $projId = Get-TasksProjectId
  $it = (Invoke-GitLab 'GET' "/api/v4/projects/$projId/issues/$Iid" $null).Text | ConvertFrom-Json
  $assignees = (@($it.assignees) | ForEach-Object { $_.username }) -join ', '
  $parts = @(
    (Format-Issue $it),
    "    author: $($it.author.username) | assignees: $assignees | created: $($it.created_at) | updated: $($it.updated_at)",
    '',
    (Normalize-Text $it.description)
  )
  if ($Notes) {
    $items = Get-AllPages "/api/v4/projects/$projId/issues/$Iid/notes?sort=asc&order_by=created_at"
    foreach ($n in $items) {
      if ($n.system -and -not $IncludeSystem) { continue }
      $parts += ''
      $parts += "=== #note_$($n.id) | $($n.author.username) | $($n.created_at) ==="
      $parts += (Normalize-Text $n.body)
    }
  }
  Write-Result ($parts -join "`n")
}

function Invoke-IssueCreate {
  if (-not $Title) { throw '-Title is required' }
  if (-not $Labels) { throw '-Labels is required (comma separated, exact names)' }
  $body = Read-BodyFile
  $projId = Get-TasksProjectId
  $wanted = Split-Labels $Labels
  $bad = @($wanted | Where-Object { $ForbiddenLabels -contains $_ })
  if ($bad.Count) { throw "forbidden labels: $($bad -join ', ')" }
  $known = @(Get-AllPages "/api/v4/projects/$projId/labels?include_ancestor_groups=true" | ForEach-Object { $_.name })
  $missing = @($wanted | Where-Object { $known -cnotcontains $_ })
  if ($missing.Count) { throw "labels not found (exact spelling and case): $($missing -join ', ')" }
  $assigneeIds = @()
  if ($Assignee) {
    $u = ConvertFrom-JsonArray (Invoke-GitLab 'GET' "/api/v4/users?username=$([Uri]::EscapeDataString($Assignee))" $null).Text
    if ($u.Count -eq 0) { throw "user not found: $Assignee" }
    $assigneeIds = @([int]$u[0].id)
  }
  if ($body -match '(?m)^/(label|assign|unlabel)\b') { Write-Note 'note: the body contains quick actions (/label, /assign); GitLab applies them too' }
  if ($DryRun) {
    Write-Output "dry-run: would create issue in project $projId"
    Write-Output "title: $Title"
    Write-Output "labels: $($wanted -join ', ')"
    Write-Output "assignee: $(if ($Assignee) { $Assignee } else { '(none)' })"
    Write-Output "body: $($body.Length) chars, first line: $(($body -split "`n")[0])"
    return
  }
  Assert-Approved 'issue-create'
  $payload = @{ title = $Title; description = $body; labels = ($wanted -join ',') }
  if ($assigneeIds.Count) { $payload.assignee_ids = $assigneeIds }
  $it = (Invoke-GitLab 'POST' "/api/v4/projects/$projId/issues" $payload).Text | ConvertFrom-Json
  Write-Output "created $(Format-Issue $it)"
}

function Invoke-IssueDelete {
  if (-not $Iid) { throw '-Iid is required' }
  $projId = Get-TasksProjectId
  $it = (Invoke-GitLab 'GET' "/api/v4/projects/$projId/issues/$Iid" $null).Text | ConvertFrom-Json
  if ($DryRun) {
    Write-Output "dry-run: would delete #$Iid [$($it.state)] $($it.title)"
    Write-Output $it.web_url
    return
  }
  Assert-Approved 'issue-delete'
  $r = Invoke-GitLab 'DELETE' "/api/v4/projects/$projId/issues/$Iid" $null
  Write-Output "deleted #$Iid HTTP $($r.Status)"
}

function Invoke-IssueNote {
  if (-not $Iid) { throw '-Iid is required' }
  $body = Read-BodyFile
  $projId = Get-TasksProjectId
  if ($DryRun) {
    Write-Output "dry-run: would comment $($body.Length) chars on issue #$Iid in project $projId"
    return
  }
  Assert-Approved 'issue-note'
  $n = (Invoke-GitLab 'POST' "/api/v4/projects/$projId/issues/$Iid/notes" @{ body = $body }).Text | ConvertFrom-Json
  $it = (Invoke-GitLab 'GET' "/api/v4/projects/$projId/issues/$Iid" $null).Text | ConvertFrom-Json
  Write-Output "posted $($it.web_url)#note_$($n.id)"
  if ((Normalize-Text $n.body) -eq (Normalize-Text $body)) {
    Write-Output 're-read: body matches the approved draft'
  } else {
    Write-Output 're-read: BODY MISMATCH - open the note and compare with the draft'
    exit 2
  }
}

function Invoke-WikiFile {
  if (-not $Slug) { throw '-Slug is required (uploads/... path or full URL)' }
  if (-not $Out) { throw '-Out is required' }
  $path = $Slug.Trim()
  $marker = $path.IndexOf('uploads/')
  if ($marker -ge 0) { $path = $path.Substring($marker) }
  $path = ($path -split '[#?]')[0].TrimStart('/')
  if (-not $path.StartsWith('uploads/')) { throw 'wiki-file only copies paths under uploads/' }
  $src = Join-Path $WikiClone ($path.Replace('/', [IO.Path]::DirectorySeparatorChar))
  if (-not (Test-Path -LiteralPath $src)) {
    $refs = @($Ref)
    if ($Ref -eq 'HEAD') { $refs += 'origin/main' }
    $blob = Join-Path $env:TEMP ('wiki-file-' + [Guid]::NewGuid().ToString('n'))
    $err = ''
    $shown = $false
    foreach ($candidate in $refs) {
      $args = (Get-WikiGitArgs) + @('show', ($candidate + ':' + $path))
      $p = New-Object System.Diagnostics.Process
      $p.StartInfo.FileName = 'git'
      $p.StartInfo.Arguments = ($args | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
      $p.StartInfo.RedirectStandardOutput = $true
      $p.StartInfo.RedirectStandardError = $true
      $p.StartInfo.UseShellExecute = $false
      $p.StartInfo.CreateNoWindow = $true
      [void]$p.Start()
      $fs = [IO.File]::Create($blob)
      try { $p.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Close() }
      $err = $p.StandardError.ReadToEnd()
      $p.WaitForExit()
      if ($p.ExitCode -eq 0) { $shown = $true; break }
      Remove-Item -LiteralPath $blob -ErrorAction SilentlyContinue
    }
    if (-not $shown) { throw "upload not in wiki-ro: $path $err" }
    $src = $blob
  }
  $full = Resolve-UserPath $Out
  $dir = Split-Path -Parent $full
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  [IO.File]::Copy($src, $full, $true)
  if ($src.StartsWith($env:TEMP)) { Remove-Item -LiteralPath $src -ErrorAction SilentlyContinue }
  Write-Output "written $full ($((Get-Item -LiteralPath $full).Length) bytes)"
}

function Invoke-RestGet {
  if (-not $ApiPath) { throw '-ApiPath is required' }
  $p = $ApiPath
  if (-not $p.StartsWith('/')) { $p = '/' + $p }
  if (-not $p.StartsWith('/api/')) { $p = '/api/v4' + $p }
  Write-Result (Invoke-GitLab 'GET' $p $null).Text
}

function Invoke-RawGraphql {
  if (-not $QueryFile) { throw '-QueryFile is required' }
  $query = [IO.File]::ReadAllText((Resolve-UserPath $QueryFile), $Utf8)
  if ($query -match '(?m)^\s*mutation\b') { Assert-Approved 'this GraphQL mutation' }
  $vars = @{}
  if ($VariablesJson) { $vars = $VariablesJson | ConvertFrom-Json }
  Write-Result (Invoke-GitLab 'POST' '/api/graphql' @{ query = $query; variables = $vars }).Text
}

# ---------------------------------------------------------------- main

try {
  switch ($Command.ToLowerInvariant()) {
    'help'             { Show-Help }
    'wiki-refresh'     { Invoke-WikiRefresh }
    'wiki-version'     { Invoke-WikiVersion }
    'wiki-page'        { Invoke-WikiPage }
    'wiki-update'      { Invoke-WikiUpdate }
    'catalog-status'   { Invoke-CatalogStatus }
    'wiki-notes'       { Invoke-WikiNotes }
    'wiki-note'        { Invoke-WikiNote }
    'wiki-post'        { Invoke-WikiPost }
    'wiki-note-update' { Invoke-WikiNoteUpdate }
    'wiki-note-delete' { Invoke-WikiNoteDelete }
    'wiki-file'        { Invoke-WikiFile }
    'labels'           { Invoke-Labels }
    'issue-search'     { Invoke-IssueSearch }
    'issue-get'        { Invoke-IssueGet }
    'issue-create'     { Invoke-IssueCreate }
    'issue-note'       { Invoke-IssueNote }
    'issue-delete'     { Invoke-IssueDelete }
    'rest-get'         { Invoke-RestGet }
    'graphql'          { Invoke-RawGraphql }
    default            { throw "unknown command '$Command'. Run without arguments for help." }
  }
} catch {
  [Console]::Error.WriteLine('ERROR: ' + $_.Exception.Message)
  exit 1
}
