$tokensPath = "lib"
$exempts = @("lib/theme/tokens.dart", "lib/ui/glass_surface.dart")

$violations = 0

function Check-File($file) {
    $content = Get-Content $file -Raw
    $found = $false

    # Special exemption for glass_surface.dart for specific elements
    if ($file -like "*glass_surface.dart*") {
        # Allow Colors.transparent and BorderRadius.circular in glass_surface
        $content = $content -replace "Colors\.transparent", "EXEMPT_COLOR"
        $content = $content -replace "BorderRadius\.circular\(", "EXEMPT_RADIUS"
    }

    # 1. Hex colors: 0x[0-9A-Fa-f]{8}
    if ($content -match "0x[0-9A-Fa-f]{8}") {
        Write-Host "Violation: Hex Color (0x...) in $file" -ForegroundColor Red
        $found = $true
    }
    # 2. Color( or Color.fromRGBO(
    if ($content -match "Color\(|Color\.fromRGBO\(") {
        Write-Host "Violation: Color() or Color.fromRGBO() in $file" -ForegroundColor Red
        $found = $true
    }
    # 3. Colors. (except Colors.transparent)
    if ($content -match "Colors\.(?!transparent)") {
        Write-Host "Violation: Colors. constant in $file" -ForegroundColor Red
        $found = $true
    }
    # 4. fontSize: \d
    if ($content -match "fontSize:\s*\d") {
        Write-Host "Violation: numeric fontSize in $file" -ForegroundColor Red
        $found = $true
    }
    # 5. TextStyle(
    if ($content -match "TextStyle\(") {
        Write-Host "Violation: TextStyle() in $file" -ForegroundColor Red
        $found = $true
    }
    # 6. BorderRadius.circular(
    if ($content -match "BorderRadius\.circular\(") {
        Write-Host "Violation: BorderRadius.circular() in $file" -ForegroundColor Red
        $found = $true
    }
    # 7. "Icons."
    if ($content -match "Icons\.") {
        Write-Host "Violation: Icons. (Material) in $file" -ForegroundColor Red
        $found = $true
    }
    # 8. "BackdropFilter" (exempt glass_surface)
    if ($file -notlike "*glass_surface.dart*" -and ($content -match "BackdropFilter")) {
        Write-Host "Violation: BackdropFilter in $file" -ForegroundColor Red
        $found = $true
    }

    return $found
}

$files = Get-ChildItem -Path $tokensPath -Recurse -Filter *.dart
foreach ($f in $files) {
    $path = $f.FullName

    # Theme files are completely exempt from the script's checks
    if ($path -like "*lib/theme*") {
        continue
    }

    if (Check-File $path) {
        $violations++
    }
}

if ($violations -gt 0) {
    Write-Host "`nTotal violations found: $violations" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nNo design violations found!" -ForegroundColor Green
    exit 0
}
