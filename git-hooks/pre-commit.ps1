# Pre-commit hook (PowerShell variant) — Shai-Hulud / TeamPCP supply chain audit.
#
# Default (fast, ~1-2s):
#   - Project-level: scripts/detect_compromise.py (if present)
#
# Opt-in (slow, ~5min — kept out of commit path; runs in CI instead):
#   - Machine-level: ~/.shai-hulud/shai-hulud-audit.ps1
#     Re-enable by setting $env:SHAI_HULUD_MACHINE_AUDIT = "1" in your shell.
#
# Override to always scan even on non-dep commits:
#     $env:SHAI_HULUD_FORCE = "1"
#
# Usage: install as .git/hooks/pre-commit.ps1 and invoke from a wrapper:
#   .git/hooks/pre-commit  contains:
#       #!/usr/bin/env sh
#       exec pwsh -NoProfile -File "$(dirname "$0")/pre-commit.ps1"
#
# Or, on a Windows-only project, set core.hooksPath to a dir containing this
# file renamed to pre-commit.ps1 + a one-line wrapper.

$ErrorActionPreference = "Continue"

$repoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) {
    Write-Host "pre-commit: not in a git repo, skipping audit" -ForegroundColor Yellow
    exit 0
}

# --- Skip scan when no dep-related files in this commit ---
# Supply chain risk only materializes when dep manifests change. If this commit
# touches only source code, the scan adds no signal and ~45s of latency.
$depPattern = '(^|/)(requirements[^/]*\.txt|package(-lock)?\.json|pnpm-lock\.yaml|yarn\.lock|pyproject\.toml|Pipfile(\.lock)?|poetry\.lock|uv\.lock|[^/]*\.pth|\.github/workflows/.*\.ya?ml|\.claude/.*\.(js|mjs|json))$'
if ($env:SHAI_HULUD_FORCE -ne "1") {
    $staged = git diff --cached --name-only
    $hit = $false
    foreach ($f in $staged) {
        if ($f -match $depPattern) { $hit = $true; break }
    }
    if (-not $hit) {
        Write-Host "[pre-commit] no dep/workflow changes — skipping supply chain audit" -ForegroundColor Green
        exit 0
    }
}

$failed = $false

# --- Project-level scan ---
$projectScript = Join-Path $repoRoot "scripts\detect_compromise.py"
if (Test-Path $projectScript) {
    Write-Host "[pre-commit] running project audit (dep/workflow files changed)..."
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) { $py = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
    if (-not $py) {
        Write-Host "pre-commit: no python found, skipping project audit" -ForegroundColor Yellow
    } else {
        & $py $projectScript --root $repoRoot
        if ($LASTEXITCODE -ge 2) {
            Write-Host "[pre-commit] project audit FAILED (alerts present)" -ForegroundColor Red
            $failed = $true
        } elseif ($LASTEXITCODE -eq 1) {
            Write-Host "[pre-commit] project audit has warnings (continuing)" -ForegroundColor Yellow
        }
    }
}

# --- Machine-level scan: DISABLED on pre-commit (too slow: ~5min/commit) ---
# Machine-wide OSV.dev round-trips are kept out of the commit path. They still
# run in CI (.github/workflows/supply-chain-audit.yml: PR + nightly) and
# you can invoke them manually anytime with `/hulud-kit quick` in Claude Code.
if ($env:SHAI_HULUD_MACHINE_AUDIT -eq "1") {
    $machineScript = Join-Path $env:USERPROFILE ".shai-hulud\shai-hulud-audit.ps1"
    if (Test-Path $machineScript) {
        Write-Host "[pre-commit] running machine audit (quick mode)..."
        & $machineScript -Mode quick -Quiet
        if ($LASTEXITCODE -ge 2) {
            Write-Host "[pre-commit] machine audit FAILED (alerts present)" -ForegroundColor Red
            Write-Host "Run '/hulud-kit quick' or '$machineScript -Mode quick' for details."
            $failed = $true
        } elseif ($LASTEXITCODE -eq 1) {
            Write-Host "[pre-commit] machine audit has warnings (continuing)" -ForegroundColor Yellow
        }
    }
}

if ($failed) {
    Write-Host ""
    Write-Host "Commit blocked by supply chain audit." -ForegroundColor Red
    Write-Host "  - Review findings above"
    Write-Host "  - See docs/security/IOC_DETECTION_CHECKLIST.md if present"
    Write-Host "  - Use 'git commit --no-verify' to bypass (only if you've confirmed safe)"
    exit 1
}

Write-Host "[pre-commit] supply chain audit clean" -ForegroundColor Green
exit 0
