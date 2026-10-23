# Renders every audited screen at every audited width and stages the PNGs for
# review.
#
#   powershell -File tool/audit_shots.ps1 -Round before
#   powershell -File tool/audit_shots.ps1 -Round after
#
# Output: proof/audit/<round>/*.png (32 shots: 8 screens x 4 widths).
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('before', 'after')]
    [string]$Round
)

$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')

try {
    $env:SONORE_VISUAL_AUDIT = '1'
    flutter test test/visual_audit/audit_shots_test.dart --update-goldens
    if ($LASTEXITCODE -ne 0) { throw "flutter test failed" }

    $outDir = Join-Path 'proof' "audit\$Round"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    Copy-Item 'test\visual_audit\goldens\*.png' $outDir -Force

    Write-Host "`nWrote $((Get-ChildItem $outDir -Filter *.png).Count) shots to proof/audit/$Round" -ForegroundColor Green
}
finally {
    Remove-Item Env:SONORE_VISUAL_AUDIT -ErrorAction SilentlyContinue
    Pop-Location
}
