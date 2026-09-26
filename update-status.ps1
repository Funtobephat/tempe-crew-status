# Snapshots TempeMassacre's git state into status.json and pushes it to the private tempe-crew-status repo.
# Called in the background by TempeMassacre's post-commit / post-merge / post-rewrite hooks, so it must never
# block or fail a commit. Only commit metadata leaves the machine: no game files, no diffs.
param([string]$Repo = "C:\Users\Joe\Downloads\PoE2-Joe\TempeMassacre")
$ErrorActionPreference = "Continue"
# Hooks run with GIT_DIR/GIT_INDEX_FILE/... set to the committing repo (a worktree's .git/worktrees/<name> for agent
# lanes). Inherited, they point every git call below - including the add/commit/push of THIS repo - at that one, which
# committed status.json into a game branch, broke the push ("'origin' does not appear to be a git repository") and hung
# the per-worktree status scan while it held the lock.
Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
$here = $PSScriptRoot
$log = Join-Path $here "update.log"
$rerun = Join-Path $here ".rerun"
function G { & git -C $Repo @args 2>$null }

# One run at a time; a run that finds the lock flags a rerun so a burst of commits collapses into one push.
try { $fs = [IO.File]::Open((Join-Path $here ".update.lock"), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { New-Item $rerun -ItemType File -Force | Out-Null; exit 0 }
try {
  do {
    Remove-Item $rerun -ErrorAction SilentlyContinue
    $branches = @(G for-each-ref refs/heads --format="%(refname:short)`t%(objectname:short)`t%(committerdate:iso-strict)`t%(subject)") | ForEach-Object {
      $f = $_ -split "`t", 4
      G merge-base --is-ancestor $f[0] master; $merged = ($LASTEXITCODE -eq 0)
      [ordered]@{ name = $f[0]; sha = $f[1]; date = $f[2]; subject = $f[3]; ahead = [int](G rev-list --count "master..$($f[0])"); merged = $merged }
    }
    $worktrees = @(); $cur = $null
    foreach ($l in (G worktree list --porcelain)) {
      if ($l -like 'worktree *') { $cur = [ordered]@{ folder = ""; path = $l.Substring(9); branch = $null; dirty = 0 }; $worktrees += $cur }
      elseif ($l -like 'branch *') { $cur.branch = $l.Substring(7) -replace '^refs/heads/', '' }
    }
    foreach ($w in $worktrees) { $w.dirty = @(git -C $w.path status --porcelain 2>$null).Count; $w.folder = Split-Path $w.path -Leaf; $w.Remove('path') }
    $commits = @(G log --all -40 --date-order --format="%h`t%cI`t%D`t%s") | ForEach-Object {
      $f = $_ -split "`t", 4; [ordered]@{ sha = $f[0]; date = $f[1]; refs = $f[2]; subject = $f[3] }
    }
    $body = [ordered]@{ master = (G rev-parse --short master); branches = $branches; worktrees = $worktrees; commits = $commits }
    $bodyJson = $body | ConvertTo-Json -Depth 6 -Compress
    $cache = Join-Path $here ".last-body.json"
    if (-not (Test-Path $cache) -or [IO.File]::ReadAllText($cache) -ne $bodyJson) {
      $body.generatedAt = (Get-Date).ToString("o")
      [IO.File]::WriteAllText((Join-Path $here "status.json"), ($body | ConvertTo-Json -Depth 6))
      git -C $here add status.json 2>$null
      git -C $here commit -q -m "status $($body.master) $(Get-Date -Format s)" 2>$null
      $push = git -C $here push -q origin HEAD:main 2>&1
      if ($LASTEXITCODE -eq 0) { [IO.File]::WriteAllText($cache, $bodyJson) }
      Add-Content $log "$(Get-Date -Format s) push $(if ($LASTEXITCODE) { 'FAILED: ' + ($push -join ' ') } else { 'ok' })"
    }
  } while (Test-Path $rerun)
} finally { $fs.Close() }
