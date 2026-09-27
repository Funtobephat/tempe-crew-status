# Snapshots TempeMassacre's git state into status.json and pushes it to the private tempe-crew-status repo.
# Run every minute by the scheduled task "TempeCrewBoardStatus" (run-hidden.vbs) and by TempeMassacre's post-commit /
# post-merge / post-rewrite hooks, so it must never block or fail a commit. Only commit metadata leaves the machine:
# no game files, no diffs.
#
# v2 (board went 2-3 min between updates): a run scanned ALL ~78 agent worktrees with `git status` (~22 s idle, far more
# while sub-agents run Unreal) plus merge-base/rev-list for ~80 branches (~7 s), then committed and pushed - over a
# minute under load, so the task's IgnoreNew policy skipped the next trigger. It also pushed only when something
# changed, and compared branches against a stale `master`. Now:
#   - only HOT worktrees are re-scanned (branch tip or index touched in the last $HotHours); cold ones reuse the cached
#     dirty count, so old rounds' worktrees cost nothing;
#   - branch ahead/merged numbers are cached per (branch sha, base sha) and only recomputed when either moves;
#   - the base branch is whatever the main worktree has checked out (guns-procedural), not `master`;
#   - every run publishes (generatedAt heartbeat), so the board's snapshot time advances each minute;
#   - each run logs its duration and warns above 45 s.
param([string]$Repo = "C:\Users\Joe\Downloads\PoE2-Joe\TempeMassacre", [double]$HotHours = 3)
$ErrorActionPreference = "Continue"
# Runs every minute in the background: low CPU priority (inherited by the git child processes) so it never competes
# with the game, the editor or the sub-agents' Unreal runs.
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch {}
# Hooks run with GIT_DIR/GIT_INDEX_FILE/... set to the committing repo (a worktree's .git/worktrees/<name> for agent
# lanes). Inherited, they point every git call below - including the add/commit/push of THIS repo - at that one, which
# committed status.json into a game branch, broke the push ("'origin' does not appear to be a git repository") and hung
# the per-worktree status scan while it held the lock.
Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue }
$here = $PSScriptRoot
$log = Join-Path $here "update.log"
$rerun = Join-Path $here ".rerun"
$branchCacheFile = Join-Path $here ".branch-cache.json"
$dirtyCacheFile = Join-Path $here ".dirty-cache.json"
function G { & git -C $Repo @args 2>$null }
function LoadMap([string]$f) { $m = @{}; if (Test-Path $f) { try { (Get-Content $f -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $m[$_.Name] = $_.Value } } catch {} }; return $m }

# One run at a time; a run that finds the lock flags a rerun so a burst of commits collapses into one push.
try { $fs = [IO.File]::Open((Join-Path $here ".update.lock"), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { New-Item $rerun -ItemType File -Force | Out-Null; exit 0 }
try {
  $passes = 0
  do {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $passes++
    Remove-Item $rerun -ErrorAction SilentlyContinue
    $base = G branch --show-current; if (-not $base) { $base = "master" }
    $baseSha = G rev-parse --short $base
    $now = Get-Date; $hotSince = $now.AddHours(-$HotHours)

    $bc = LoadMap $branchCacheFile; $bcNew = @{}; $computed = 0
    $branches = @(G for-each-ref refs/heads --format="%(refname:short)`t%(objectname:short)`t%(committerdate:iso-strict)`t%(subject)") | ForEach-Object {
      $f = $_ -split "`t", 4
      $key = "$($f[1])@$baseSha"
      if ($bc.ContainsKey($f[0]) -and $bc[$f[0]].key -eq $key) { $ahead = [int]$bc[$f[0]].ahead; $merged = [bool]$bc[$f[0]].merged }
      else {
        G merge-base --is-ancestor $f[0] $base; $merged = ($LASTEXITCODE -eq 0)
        $ahead = [int](G rev-list --count "$base..$($f[0])"); $computed++
      }
      $bcNew[$f[0]] = [ordered]@{ key = $key; ahead = $ahead; merged = $merged }
      [ordered]@{ name = $f[0]; sha = $f[1]; date = $f[2]; subject = $f[3]; ahead = $ahead; merged = $merged }
    }
    $byBranch = @{}; foreach ($b in $branches) { $byBranch[$b.name] = $b }

    $dc = LoadMap $dirtyCacheFile; $dcNew = @{}; $scanned = 0
    $worktrees = @(); $cur = $null
    foreach ($l in (G worktree list --porcelain)) {
      if ($l -like 'worktree *') { $cur = [ordered]@{ folder = ""; path = $l.Substring(9); branch = $null; dirty = 0 }; $worktrees += $cur }
      elseif ($l -like 'branch *') { $cur.branch = $l.Substring(7) -replace '^refs/heads/', '' }
    }
    foreach ($w in $worktrees) {
      $p = $w.path -replace '/', '\'
      # index location: <repo>\.git\index for the main worktree, <gitdir>\index for linked ones (.git is a file there)
      $gitMark = Join-Path $p ".git"; $index = $null
      if (Test-Path $gitMark -PathType Container) { $index = Join-Path $gitMark "index" }
      elseif (Test-Path $gitMark) { $gd = ((Get-Content $gitMark -TotalCount 1) -replace '^gitdir:\s*', '').Trim(); $index = Join-Path $gd "index" }
      $touched = if ($index -and (Test-Path $index)) { (Get-Item $index).LastWriteTime } else { [datetime]::MinValue }
      $tip = if ($w.branch -and $byBranch[$w.branch]) { [datetime]$byBranch[$w.branch].date } else { [datetime]::MinValue }
      $hot = ($touched -gt $hotSince) -or ($tip -gt $hotSince) -or ($p -eq $Repo)
      $w.active = $null
      if ($hot -or -not $dc.ContainsKey($p)) {
        $st = @(git -C $p status --porcelain 2>$null); $w.dirty = $st.Count; $scanned++
        # latest edit among the uncommitted files = when the agent last actually worked in this lane (cards show it)
        $latest = [datetime]::MinValue
        foreach ($line in ($st | Select-Object -First 400)) {
          $rel = $line.Substring(3).Trim('"'); if ($rel -match ' -> ') { $rel = $rel.Split(' -> ')[-1] }
          $fp = Join-Path $p ($rel -replace '/', '\')
          if (Test-Path -LiteralPath $fp -PathType Leaf) { $t = (Get-Item -LiteralPath $fp).LastWriteTime; if ($t -gt $latest) { $latest = $t } }
        }
        if ($st.Count -gt 0 -and $latest -gt [datetime]::MinValue) { $w.active = $latest.ToString("o") }   # only real uncommitted work counts as activity
      } else { $w.dirty = [int]$dc[$p] }
      $dcNew[$p] = $w.dirty
      $w.folder = Split-Path $p -Leaf; $w.Remove('path')
    }
    $commits = @(G log --all -40 --date-order --format="%h`t%cI`t%D`t%s") | ForEach-Object {
      $f = $_ -split "`t", 4; [ordered]@{ sha = $f[0]; date = $f[1]; refs = $f[2]; subject = $f[3] }
    }
    ($bcNew | ConvertTo-Json -Depth 4) | Set-Content $branchCacheFile -Encoding utf8
    ($dcNew | ConvertTo-Json -Depth 2) | Set-Content $dirtyCacheFile -Encoding utf8

    # `master` keeps its name in the JSON for the page, but now carries the live base branch.
    $body = [ordered]@{ master = $baseSha; base = $base; branches = $branches; worktrees = $worktrees; commits = $commits }
    $body.generatedAt = $now.ToString("o")   # heartbeat: every run publishes, so the board's snapshot time moves each minute
    [IO.File]::WriteAllText((Join-Path $here "status.json"), ($body | ConvertTo-Json -Depth 6))
    git -C $here add status.json 2>$null
    git -C $here commit -q -m "status $baseSha $(Get-Date -Format s)" 2>$null
    $push = git -C $here push -q origin HEAD:main 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $msg = "$(Get-Date -Format s) push $(if ($ok) { 'ok' } else { 'FAILED: ' + ($push -join ' ') }) in $sec s (scanned $scanned/$($worktrees.Count) worktrees, $computed branch recomputes)"
    if ($sec -gt 45) { $msg += "  WARN: run over 45 s - the next minute's trigger may be skipped" }
    Add-Content $log $msg
  } while ((Test-Path $rerun) -and $passes -lt 2)
} finally { $fs.Close() }
