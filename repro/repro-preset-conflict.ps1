#requires -Version 5.1
<#
.SYNOPSIS
  Reproduce the DSH 0.2.1-rc.2 "new session fails after adding @local plugin bundles" incident
  in a fully isolated $DSH_HOME, with A/B controls.

.DESCRIPTION
  Incident (2026-10-18, DSH desktop 0.2.1-rc.2, Windows):
    after adding nine `@local/dsh-plugin-*` bundles (each bundle patch inserted itself, and each
    package re-exported `@deepseek-ai/dsh-mcp-client`) and running `pnpm add file:./plugins/*`,
    creating a session failed with:
      agent-preset/invalid: persona (...): prompt section "deployment:persona-prefix" is already
      registered (for a per-agent override, register through that agent's `agent.ctx` instead)
      tool-subagent (...): tool-subagent: standing `modelSelectionSettings` requires a scoped
      preset Context

  What this script establishes mechanically, without touching the user's profile or app process:
    1. An isolated Harness home (only `profiles/`, never sessions or credentials) can boot the
       incident layout; `dsh web` starts and composes the same 215-entry tree as the healthy one.
    2. The profile carries a second copy of @deepseek-ai/dsh-scope (and dsh-system-prompt, ...).
       Two copies in one process have two distinct `Symbol("dsh.scope")` tags, so a Context scoped
       by one copy reads as UNSCOPED to the other copy. That is exactly the condition that makes
       `persona` register its prompt section globally (colliding with the deployment persona) and
       makes `tool-subagent` reject the preset Context. `scope-split-proof.mjs` proves this
       in-process for every variant.
    3. A/B: removing the second `dsh-system-prompt` copy (or the whole second core-package set)
       removes the split; the minimal failing set is reported.

  The final click ("new session") is done by a browser: this script can drive it with `-WithUi`,
  but under a restricted DSH sandbox the Chromium renderer CDP session may not answer
  (browser-process CDP works, `Runtime.*` for the page never replies), which is an automation
  limitation, not a DSH finding. Run `-WithUi` from a normal desktop session for the toast.

.PARAMETER WithUi
  Boot the web UI and press "new session" through Edge/CDP, capturing body text + screenshot.
.PARAMETER SkipWeb
  Only run --dump-config and the in-process scope proof (fastest, no servers started).
.PARAMETER KeepWork
  Keep $WorkRoot (isolated homes) after the run.
.PARAMETER Port
  Base TCP port for the web boots (default 51871; +1 per boot).
#>
param(
  [string]$WorkRoot = (Join-Path $PSScriptRoot 'work'),
  [string]$BadProfile = 'C:\Users\Admin\dsh-removed-20261018\profiles\desktop',
  [string]$GoodProfile = 'C:\Users\Admin\.dsh\profiles\desktop',
  [string]$EvidenceDir = (Join-Path $PSScriptRoot 'evidence'),
  [switch]$WithUi,
  [switch]$SkipWeb,
  [switch]$KeepWork,
  [int]$Port = 51871,
  [int]$BootTimeoutSec = 150
)
$ErrorActionPreference = 'Stop'
$script:Here = $PSScriptRoot
$script:Exe = 'C:\Users\Admin\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe'
$script:Bin = 'C:\Users\Admin\AppData\Local\Programs\DeepSeek Harness\resources\app.asar\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js'
$script:InstallModules = 'C:\Users\Admin\AppData\Local\Programs\DeepSeek Harness\resources\app.asar\dsh\node_modules'
$script:BadPkg = Join-Path $BadProfile 'package.json.bak-20261018-222809'
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Logs = New-Object System.Collections.Generic.List[string]

function Say([string]$m) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
  Write-Host $line
  $script:Logs.Add($line)
}
function Assert-Isolation {
  # Never allow the isolated work root to overlap the live home or a profile we only read.
  $full = [IO.Path]::GetFullPath($WorkRoot)
  $scHome = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.dsh'))
  if ($full -eq $scHome -or $full.StartsWith($scHome + '\')) { throw "refusing to use a work root inside the live home: $full" }
  if (-not $full.StartsWith([IO.Path]::GetFullPath($script:Here))) { throw "work root must live under $script:Here (got $full)" }
  foreach ($src in @($BadProfile, $GoodProfile)) {
    if ($full -eq [IO.Path]::GetFullPath($src) -or $full.StartsWith([IO.Path]::GetFullPath($src) + '\')) { throw "work root must not be inside a source profile: $src" }
  }
}
function Write-Text([string]$path, [string]$text) {
  # UTF-8 without BOM: DSH parses package.json with JSON.parse and rejects a BOM.
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function Invoke-Cli {
  # Argument vector is built here, never supplied by the caller as an array.
  param([string]$DshHome, [string]$ProfileName, [switch]$DumpConfig, [switch]$Version, [int]$TimeoutSec = 150)
  $CliArgs = @('--profile', $ProfileName)
  if ($DumpConfig) { $CliArgs += '--dump-config' }
  if ($Version) { $CliArgs += '--version' }
  $env:DSH_HOME = $DshHome
  $env:ELECTRON_RUN_AS_NODE = '1'
  $env:DSH_PROFILE = ''
  $sw = [Diagnostics.Stopwatch]::StartNew()
  # Capture every stream through the pipeline (works in pwsh 7; in Windows PowerShell 5.1 the
  # stderr ErrorRecords are stringified by the ForEach-Object). Run this script with `pwsh`.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $all = & $script:Exe $script:Bin @CliArgs 2>&1 | ForEach-Object { $_.ToString() }
    $code = $LASTEXITCODE
  } catch {
    $all = @($_.ToString()); $code = -1
  } finally {
    $ErrorActionPreference = $prevEap
  }
  $sw.Stop()
  [pscustomobject]@{ ExitCode = $code; Output = (($all -join "`n") -replace "`r", ''); Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}
function Copy-Tree([string]$From, [string]$To) {
  robocopy $From $To /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $From -> $To" }
}

# Build one isolated profile. $Flavor decides the local plugin implementation:
#   'good' = marker packages (no re-export), 'bad' = `export * from '@deepseek-ai/dsh-mcp-client'`
# $CoreCopies lists @deepseek-ai packages copied into the profile's node_modules.
function New-Scenario {
  param([string]$Name, [ValidateSet('good', 'bad')][string]$Flavor, [string[]]$CoreCopies)
  $scHome = Join-Path $WorkRoot "home-$Name"
  $prof = Join-Path $scHome "profiles\$Name"
  if (Test-Path $scHome) { Remove-Item $scHome -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $prof | Out-Null

  $srcProfile = if ($Flavor -eq 'bad') { $BadProfile } else { $GoodProfile }
  if ($Flavor -eq 'bad') { Copy-Item $script:BadPkg (Join-Path $prof 'package.json') } else { Copy-Item (Join-Path $srcProfile 'package.json') (Join-Path $prof 'package.json') }
  # Keep the user patch layer identical in every scenario so the A/B has one variable.
  Copy-Item (Join-Path $BadProfile 'cordis.patch.yml') (Join-Path $prof 'cordis.patch.yml')
  Copy-Item (Join-Path $srcProfile 'pnpm-workspace.yaml') (Join-Path $prof 'pnpm-workspace.yaml')

  Copy-Tree (Join-Path $srcProfile 'plugins') (Join-Path $prof 'plugins')
  Copy-Tree (Join-Path $srcProfile 'plugins') (Join-Path $prof 'node_modules\@local')
  foreach ($p in (Get-ChildItem (Join-Path $prof 'node_modules\@local') -Directory)) {
    Rename-Item $p.FullName (Join-Path $p.Parent.FullName ('dsh-plugin-' + $p.Name))
  }
  $destCore = Join-Path $prof 'node_modules\@deepseek-ai'
  # NOTE: do not name this loop variable $name 閳?PowerShell is case-insensitive and $Name is the
  # parameter carrying the scenario name.
  foreach ($pkgName in $CoreCopies) {
    $src = Join-Path $BadProfile "node_modules\@deepseek-ai\$pkgName"
    if (-not (Test-Path $src)) { $src = Join-Path $GoodProfile "node_modules\@deepseek-ai\$pkgName" }
    if (-not (Test-Path $src)) { throw "core package not found: $pkgName" }
    Copy-Tree $src (Join-Path $destCore $pkgName)
  }
  [pscustomobject]@{ Name = $Name; Home = $scHome; ProfileDir = $prof; Flavor = $Flavor; CoreCopies = $CoreCopies }
}
function Get-CoreCopies([string]$SourceProfile) {
  $dir = Join-Path $SourceProfile 'node_modules\@deepseek-ai'
  @(Get-ChildItem $dir -Directory | Select-Object -ExpandProperty Name) | Sort-Object
}
function Test-ScopeSplit {
  param([pscustomobject]$Scenario)
  $out = Join-Path $EvidenceDir ("scope-split-$($Scenario.Name).json")
  $env:ELECTRON_RUN_AS_NODE = '1'
  $text = & $script:Exe (Join-Path $script:Here 'scope-split-proof.mjs') $script:InstallModules (Join-Path $Scenario.ProfileDir 'node_modules') $out 2>&1 | ForEach-Object { $_.ToString() }
  $code = $LASTEXITCODE
  $split = $null
  if (Test-Path $out) { try { $split = Get-Content $out -Raw | ConvertFrom-Json } catch {} }
  [pscustomobject]@{
    ExitCode = $code
    HasProfileScopeCopy = Test-Path (Join-Path $Scenario.ProfileDir 'node_modules\@deepseek-ai\dsh-scope')
    FailureMode = if ($split) { $split.failureMode } else { (($text -join ' ') -replace '\s+', ' ').Trim() }
    Confirmed = [bool]($split -and $split.ok)
    Evidence = $out
  }
}
function Stop-Tree($proc) {
  if ($proc -and -not $proc.HasExited) {
    try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 800
  }
}
function Start-WebBoot {
  param([pscustomobject]$Scenario, [int]$Port, [string]$Tag)
  $env:DSH_HOME = $Scenario.Home; $env:ELECTRON_RUN_AS_NODE = '1'; $env:DSH_PROFILE = ''
  $stdout = Join-Path $EvidenceDir "web-$Tag.out.log"
  $stderr = Join-Path $EvidenceDir "web-$Tag.err.log"
  Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue
  $proc = Start-Process -FilePath $script:Exe -ArgumentList @("`"$($script:Bin)`"", '--profile', $Scenario.Name, '--no-open', '--host', '127.0.0.1', '--port', $Port) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden
  $deadline = (Get-Date).AddSeconds($BootTimeoutSec)
  $url = $null
  while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { break }
    $txt = ((Get-Content $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue))
    if ($txt -match 'dsh web: (http://127\.0\.0\.1:\d+/\?token=\S+)') { $url = $Matches[1]; break }
    Start-Sleep -Milliseconds 1000
  }
  $err = Get-Content $stderr -Raw -ErrorAction SilentlyContinue
  [pscustomobject]@{
    Tag = $Tag; Process = $proc; Url = $url; Stdout = $stdout; Stderr = $stderr
    Started = [bool]$url
    ExitCode = if ($proc.HasExited) { $proc.ExitCode } else { $null }
    ActivationWarnings = @(($err -split "`n") | Where-Object { $_ -match 'did not activate|failed to import' }).Count
  }
}
function Invoke-UiProbe {
  param([string]$Url, [string]$Tag)
  $edge = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', 'C:\Program Files\Microsoft\Edge\Application\msedge.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $edge) { return [pscustomobject]@{ Skipped = 'Edge not found' } }
  $cdp = 9300 + (Get-Random -Minimum 0 -Maximum 120)
  $ud = Join-Path $WorkRoot "edge-$Tag"
  $edgeProc = Start-Process -FilePath $edge -ArgumentList @('--headless=new', '--disable-gpu', '--disable-extensions', '--no-first-run', '--no-default-browser-check', "--user-data-dir=`"$ud`"", "--remote-debugging-port=$cdp", 'about:blank') -PassThru -WindowStyle Hidden
  try {
    for ($i = 0; $i -lt 20; $i++) { try { $null = Invoke-WebRequest "http://127.0.0.1:$cdp/json/version" -UseBasicParsing -TimeoutSec 2; break } catch { Start-Sleep -Milliseconds 500 } }
    $json = Join-Path $EvidenceDir "ui-probe-$Tag.json"
    $png = Join-Path $EvidenceDir "ui-probe-$Tag.png"
    $env:ELECTRON_RUN_AS_NODE = ''
    $txt = & node (Join-Path $script:Here 'ui-probe.mjs') --cdp-port $cdp --url $Url --out-json $json --out-png $png --max-wait-ms 30000 --settle-ms 8000 2>&1 | ForEach-Object { $_.ToString() }
    $probe = $null
    if (Test-Path $json) { try { $probe = Get-Content $json -Raw | ConvertFrom-Json } catch {} }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Probe = $probe; Json = $json; Png = $png; Output = ($txt -join ' ') }
  } finally { Stop-Tree $edgeProc }
}

# ---------------------------------------------------------------- run
Assert-Isolation
New-Item -ItemType Directory -Force -Path $WorkRoot, $EvidenceDir | Out-Null
Say "work root : $WorkRoot"
Say "evidence  : $EvidenceDir"
Say "app       : $script:Exe"
$ver = Invoke-Cli -DshHome (Join-Path $WorkRoot 'home-version') -ProfileName web -Version -TimeoutSec 60
Say "dsh version: $($ver.Output.Trim()) (exit $($ver.ExitCode))"
Write-Text (Join-Path $EvidenceDir 'environment.json') (ConvertTo-Json ([pscustomobject]@{
  timestamp = (Get-Date).ToString('o'); os = [Environment]::OSVersion.VersionString; pwsh = $PSVersionTable.PSVersion.ToString()
  app = $script:Exe; dshBin = $script:Bin; dshVersion = $ver.Output.Trim()
  node = (& node -v); badProfile = $BadProfile; goodProfile = $GoodProfile
}) -Depth 5)

$goodCopies = Get-CoreCopies $GoodProfile
$badCopies = Get-CoreCopies $BadProfile
Say "good profile @deepseek-ai copies ($($goodCopies.Count)): $($goodCopies -join ',')"
Say "bad  profile @deepseek-ai copies ($($badCopies.Count)): $($badCopies -join ',')"

# Incident layout = the bad package.json bundles + the bad profiles' plugin packages + every
# second core-package copy found in that profile (minus the two multi-hundred-MB SDK dirs that
# the optional subagent bundles want; their import failure is a non-fatal "did not activate").
$incidentCopies = $badCopies
# The mechanism unit needs dsh-scope's own runtime deps to load in isolation (see README).
$minimalCopies = @('dsh-mcp-client', 'dsh-scope', 'dsh-system-prompt', 'cordis', 'cosmokit')

$scenarios = @(
  @{ Name = 'good'; Flavor = 'good'; Copies = $goodCopies; Expect = 'healthy (mirrors the current working profile)' },
  @{ Name = 'good-with-all-copies'; Flavor = 'good'; Copies = $incidentCopies; Expect = 'control: duplicate copies alone, marker plugins' },
  @{ Name = 'incident'; Flavor = 'bad'; Copies = $incidentCopies; Expect = 'incident layout (reproduces the report)' },
  @{ Name = 'incident-no-system-prompt'; Flavor = 'bad'; Copies = ($incidentCopies | Where-Object { $_ -ne 'dsh-system-prompt' }); Expect = 'A/B: remove the second dsh-system-prompt copy' },
  @{ Name = 'incident-no-scope'; Flavor = 'bad'; Copies = ($incidentCopies | Where-Object { $_ -ne 'dsh-scope' }); Expect = 'A/B: remove the second dsh-scope copy' },
  @{ Name = 'incident-minimal'; Flavor = 'bad'; Copies = $minimalCopies; Expect = 'smallest candidate set that still loads: {mcp-client, scope, system-prompt, cordis, cosmokit}' }
)

$port = $Port
foreach ($s in $scenarios) {
  Say "== scenario $($s.Name): $($s.Expect)"
  $sc = New-Scenario -Name $s.Name -Flavor $s.Flavor -CoreCopies $s.Copies
  $dump = Invoke-Cli -DshHome $sc.Home -ProfileName $sc.Name -DumpConfig -TimeoutSec 180
  Write-Text (Join-Path $EvidenceDir "dump-config-$($s.Name).txt") $dump.Output
  $ids = ([regex]::Matches($dump.Output, '(?m)^- id: ')).Count
  $errLines = @(($dump.Output -split "`n") | Where-Object { $_ -match 'error:|skipping profile bundle|invalid' })
  $split = Test-ScopeSplit -Scenario $sc
  Say "   dump-config exit=$($dump.ExitCode) ids=$ids $($dump.Seconds)s; scope-split=$($split.Confirmed) [$($split.FailureMode)]"

  $web = $null
  if (-not $SkipWeb) {
    $web = Start-WebBoot -Scenario $sc -Port $port -Tag $s.Name
    $port++
    Say "   dsh web started=$($web.Started) url=$($web.Url)"
  }
  $ui = $null
  if ($WithUi -and $web -and $web.Started) {
    $ui = Invoke-UiProbe -Url $web.Url -Tag $s.Name
    if ($ui.Probe) { Say "   ui probe stage=$($ui.Probe.stage) clicked=$($ui.Probe.clicked) errors=$($ui.Probe.errors -join ',')" }
    else { Say "   ui probe produced no JSON" }
  }
  $script:Results.Add([pscustomobject]@{
    scenario = $s.Name; expectation = $s.Expect; flavor = $s.Flavor; coreCopies = $s.Copies
    dumpConfigExit = $dump.ExitCode; composedIds = $ids; dumpConfigErrors = $errLines; dumpSeconds = $dump.Seconds
    secondScopeCopy = $split.HasProfileScopeCopy; scopeSplitConfirmed = $split.Confirmed; scopeSplitDetail = $split.FailureMode
    webStarted = if ($web) { $web.Started } else { $null }; webUrl = if ($web) { $web.Url } else { $null }
    webActivationWarnings = if ($web) { $web.ActivationWarnings } else { $null }
    uiProbeStage = if ($ui -and $ui.Probe) { $ui.Probe.stage } else { $null }
    uiProbeErrors = if ($ui -and $ui.Probe) { @($ui.Probe.errors) } else { @() }
  })
  if ($web) { Stop-Tree $web.Process }
  Say "   done"
}

$summaryPath = Join-Path $EvidenceDir 'scenario-results.json'
$rows = @()
foreach ($r in $script:Results) { $rows += $r }
Write-Text $summaryPath (ConvertTo-Json -InputObject $rows -Depth 8)
$logPath = Join-Path $EvidenceDir 'repro-run.log'
Write-Text $logPath ($script:Logs -join "`r`n")

Write-Host ''
Write-Host '==== summary ===='
$script:Results | Format-Table -AutoSize scenario, dumpConfigExit, composedIds, secondScopeCopy, scopeSplitConfirmed, webStarted | Out-String | Write-Host
Write-Host "results   : $summaryPath"
Write-Host "run log   : $logPath"
if (-not $KeepWork) { Say "isolated homes kept for inspection: $WorkRoot (delete manually or re-run with a different -WorkRoot)" }
exit 0
