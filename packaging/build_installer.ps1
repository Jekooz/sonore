<#
.SYNOPSIS
    Builds the single-file Sonore Windows installer.

.DESCRIPTION
    Produces dist\Sonore-Setup-<version>.exe: one installer that lays down the
    app, the sidecar, a private CPython carrying the sidecar's packages and the
    yt-dlp binary, and that installs the Microsoft Visual C++ runtime when the
    machine does not already have it. The user has to install nothing by hand.

    Stages, each skippable while iterating on a later one:
      * the Flutter Windows release build of ytm_app
      * the private CPython runtime, with backend\requirements.txt installed into it
      * the staged installed layout
      * the installer itself, compiled with Inno Setup's ISCC

.PARAMETER SkipAppBuild
    Reuse the existing ytm_app release build.

.PARAMETER SkipRuntimeBuild
    Reuse the existing build\packaging\runtime\python runtime.

.PARAMETER SkipInstaller
    Stop after staging, without compiling the installer.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File packaging\build_installer.ps1
#>
[CmdletBinding()]
param(
    [switch] $SkipAppBuild,
    [switch] $SkipRuntimeBuild,
    [switch] $SkipInstaller
)

$ErrorActionPreference = 'Stop'

function Write-Step([string] $Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Assert-ExitCode([string] $What) {
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE."
    }
}

# ---- paths ---------------------------------------------------------------

$RepoRoot     = Split-Path -Parent $PSScriptRoot
$AppProject   = Join-Path $RepoRoot 'ytm_app'
$BackendDir   = Join-Path $RepoRoot 'backend'
$ExtensionDir = Join-Path $RepoRoot 'browser-extension'
$IssFile      = Join-Path $PSScriptRoot 'sonore.iss'
$WorkDir      = Join-Path $RepoRoot 'build\packaging'
$CacheDir     = Join-Path $WorkDir 'cache'
$RuntimeDir   = Join-Path $WorkDir 'runtime\python'
$StageDir     = Join-Path $WorkDir 'stage'
$DistDir      = Join-Path $RepoRoot 'dist'
$AppBuildDir  = Join-Path $AppProject 'build\windows\x64\runner\Release'

# The runtime the installer ships. 3.11 is the version the backend is developed
# against (PROJECT_CONTEXT.md); 3.11.9 is its last release with an embeddable
# build, and every package in backend/requirements.txt has a wheel for it.
$PythonVersion = '3.11.9'
$PythonUrl     = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"

# The sidecar shells out to yt-dlp for stream URLs. The official Windows build is
# a standalone binary, so playing a track needs no Python of the user's either.
$YtDlpUrl = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'

# The app's own DLLs link the Visual C++ runtime (verified in the release build's
# import table), and Windows does not ship it. This is Microsoft's permanent
# "latest supported VC++ 2015-2022 x64" link.
$VcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'

# ---- helpers -------------------------------------------------------------

function Get-Download([string] $Url, [string] $Destination) {
    if (Test-Path -LiteralPath $Destination) {
        Write-Host "    cached: $(Split-Path -Leaf $Destination)"
        return $Destination
    }
    Write-Host "    fetching: $Url"
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    $request = @{ Uri = $Url; OutFile = $Destination }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell 5.1 needs this to avoid the Internet Explorer parser.
        $request['UseBasicParsing'] = $true
    }
    Invoke-WebRequest @request
    return $Destination
}

function Find-Iscc {
    $found = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, (Join-Path $env:LOCALAPPDATA 'Programs'))
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $candidate = Join-Path $root 'Inno Setup 6\ISCC.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

# ---- the version the installer carries -----------------------------------

Write-Step 'Checking the installer version matches the app'
$pubspec = Get-Content -LiteralPath (Join-Path $AppProject 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*([0-9][0-9.]*)') {
    throw 'ytm_app\pubspec.yaml has no version line to read.'
}
$appVersion = $Matches[1]
$issText = Get-Content -LiteralPath $IssFile -Raw
if ($issText -notmatch '(?m)^#define AppVersion "([^"]+)"') {
    throw "packaging\sonore.iss has no AppVersion define to read."
}
if ($Matches[1] -ne $appVersion) {
    throw "ytm_app\pubspec.yaml is version $appVersion but packaging\sonore.iss says $($Matches[1]). Keep them in step."
}
Write-Host "    version: $appVersion"

# ---- the app -------------------------------------------------------------

if (-not $SkipAppBuild) {
    Write-Step 'Building the Windows release of the app'
    Push-Location $AppProject
    try {
        & flutter build windows --release
        Assert-ExitCode 'flutter build windows --release'
    }
    finally {
        Pop-Location
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $AppBuildDir 'sonore.exe'))) {
    throw "There is no release build at $AppBuildDir - run this script again without -SkipAppBuild."
}

# ---- the private runtime -------------------------------------------------

if (-not $SkipRuntimeBuild) {
    Write-Step "Building the private CPython $PythonVersion runtime"
    $zip = Get-Download $PythonUrl (Join-Path $CacheDir "python-$PythonVersion-embed-amd64.zip")
    if (Test-Path -LiteralPath $RuntimeDir) {
        Remove-Item -LiteralPath $RuntimeDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $RuntimeDir -Force

    # The embeddable distribution is an isolated interpreter: it only sees the
    # paths listed in its ._pth file, and site.main() only runs when that file
    # says so. Without both, nothing pip installs is importable and the sidecar
    # cannot start.
    $pth = Get-ChildItem -Path $RuntimeDir -Filter 'python3*._pth' | Select-Object -First 1
    if (-not $pth) {
        throw "The embeddable Python archive has no ._pth file in $RuntimeDir."
    }
    $stdlibZip = [IO.Path]::GetFileNameWithoutExtension($pth.Name) + '.zip'
    # ..\backend is the sidecar's own package root, beside the interpreter. An
    # isolated interpreter does not add a script's directory to sys.path, so
    # without this line backend\main.py cannot import its own `services` package.
    # The entry is relative to python.exe, so it holds wherever the app is
    # installed - Program Files, a user's profile, or a folder the user picks.
    Set-Content -LiteralPath $pth.FullName -Encoding ascii -Value @(
        $stdlibZip
        '.'
        '..\backend'
        'Lib\site-packages'
        'import site'
    )
    New-Item -ItemType Directory -Path (Join-Path $RuntimeDir 'Lib\site-packages') -Force | Out-Null

    $python = Join-Path $RuntimeDir 'python.exe'

    # pip is not part of the embeddable build; get-pip installs it into the
    # site-packages listed above.
    $getPip = Get-Download 'https://bootstrap.pypa.io/get-pip.py' (Join-Path $CacheDir 'get-pip.py')
    & $python $getPip --no-warn-script-location --disable-pip-version-check
    Assert-ExitCode 'bootstrapping pip into the runtime'

    Write-Step "Installing the sidecar's packages into the runtime"
    & $python -m pip install --no-warn-script-location --disable-pip-version-check --requirement (Join-Path $BackendDir 'requirements.txt')
    Assert-ExitCode 'pip install -r backend\requirements.txt'
}

Write-Step 'Checking the private runtime'
$python = Join-Path $RuntimeDir 'python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    throw "There is no runtime at $python - run this script again without -SkipRuntimeBuild."
}

& $python -c "import fastapi, uvicorn, ytmusicapi, keyring, pydantic; print('    packages import')"
Assert-ExitCode 'importing the sidecar packages'

# Sign-in storage is the one package that can come up without a working Windows
# backend, which would break only at run time. Write, read back and remove a
# probe credential: the same round trip the app's own session takes, and it
# cleans up after itself. The name is deliberately not the app's own.
& $python -c "import keyring; keyring.set_password('Sonore build check', 'probe', 'ok'); value = keyring.get_password('Sonore build check', 'probe'); keyring.delete_password('Sonore build check', 'probe'); assert value == 'ok', value; print('    keyring round trip')"
Assert-ExitCode 'the keyring round trip in the shipped runtime'

# ---- the staged layout ---------------------------------------------------

Write-Step 'Staging the installed layout'
if (Test-Path -LiteralPath $StageDir) {
    Remove-Item -LiteralPath $StageDir -Recurse -Force
}
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

# The app and everything it reads at run time goes flat into one folder, which is
# the layout SystemSidecarResolver looks for: the sidecar under backend\, the
# interpreter under python\, the tools beside the executable.
Copy-Item -Path (Join-Path $AppBuildDir '*') -Destination $StageDir -Recurse -Force
Copy-Item -LiteralPath $RuntimeDir -Destination (Join-Path $StageDir 'python') -Recurse -Force
Copy-Item -LiteralPath $BackendDir -Destination (Join-Path $StageDir 'backend') -Recurse -Force
Copy-Item -LiteralPath $ExtensionDir -Destination (Join-Path $StageDir 'browser-extension') -Recurse -Force
Copy-Item -LiteralPath (Get-Download $YtDlpUrl (Join-Path $CacheDir 'yt-dlp.exe')) -Destination (Join-Path $StageDir 'yt-dlp.exe') -Force
Copy-Item -LiteralPath (Get-Download $VcRedistUrl (Join-Path $CacheDir 'vc_redist.x64.exe')) -Destination (Join-Path $StageDir 'vc_redist.x64.exe') -Force

# Nothing this machine generated may ship: the backend's own bytecode caches and
# the pairing file a sign-in on this machine left behind. The installed packages'
# caches stay, because they are what keeps the sidecar's start fast.
Get-ChildItem -Path (Join-Path $StageDir 'backend') -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force
foreach ($leftover in @('sidecar.json', 'sidecar.json.tmp')) {
    Remove-Item -LiteralPath (Join-Path $StageDir "browser-extension\$leftover") -Force -ErrorAction SilentlyContinue
}
Get-ChildItem -Path $StageDir -Filter '*.pdb' -ErrorAction SilentlyContinue | Remove-Item -Force

Write-Step 'Checking the staged layout'
$required = @(
    'sonore.exe',
    'flutter_windows.dll',
    'data',
    'backend\main.py',
    'backend\services\ytmusic_client.py',
    'browser-extension\manifest.json',
    'browser-extension\service_worker.js',
    'python\python.exe',
    'yt-dlp.exe',
    'vc_redist.x64.exe'
)
foreach ($item in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $StageDir $item))) {
        throw "The staged layout is missing $item."
    }
}

# The staged copies, not this machine's: these are what the installer ships.
& (Join-Path $StageDir 'python\python.exe') -c "import fastapi, uvicorn, ytmusicapi, keyring; print('    staged runtime imports')"
Assert-ExitCode 'importing from the staged runtime'
$stagedYtDlp = & (Join-Path $StageDir 'yt-dlp.exe') --version
Assert-ExitCode 'running the staged yt-dlp'
Write-Host "    staged yt-dlp $stagedYtDlp"

# Boot the staged sidecar exactly the way the app does, and only then believe
# the layout. This is the check that catches a runtime assembled wrongly: an
# isolated interpreter's paths are fixed at build time, so a missing or wrong
# ._pth entry looks fine on disk and fails only when the app starts it.
Write-Step 'Booting the staged sidecar the way the app does'
$probePortFile = Join-Path $env:TEMP 'sonore-sidecar-probe-port.txt'
$probeOut = Join-Path $WorkDir 'sidecar-probe.log'
$probeErr = Join-Path $WorkDir 'sidecar-probe.err.log'
Remove-Item -LiteralPath $probePortFile -Force -ErrorAction SilentlyContinue
$env:YTM_PORT_FILE = $probePortFile
# The script path is quoted because it can contain spaces, and the app hands this
# path to the interpreter the same way - as one argument, never split.
$sidecarScript = Join-Path $StageDir 'backend\main.py'
$sidecar = Start-Process -FilePath (Join-Path $StageDir 'python\python.exe') `
    -ArgumentList ('"{0}"' -f $sidecarScript) `
    -WorkingDirectory (Join-Path $StageDir 'backend') `
    -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr `
    -PassThru -NoNewWindow

$probePort = $null
for ($i = 0; $i -lt 60 -and -not $sidecar.HasExited; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $probePortFile) {
        $probePort = (Get-Content -LiteralPath $probePortFile -Raw).Trim()
        if ($probePort) { break }
    }
}
$healthy = $false
if ($probePort -and -not $sidecar.HasExited) {
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $answer = (Invoke-WebRequest "http://127.0.0.1:$probePort/health" -UseBasicParsing -TimeoutSec 2).Content
            if ($answer -match 'ok') { $healthy = $true; break }
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }
}
if (-not $sidecar.HasExited) { Stop-Process -Id $sidecar.Id -Force }
Start-Sleep -Milliseconds 300
Remove-Item Env:YTM_PORT_FILE -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $probePortFile -Force -ErrorAction SilentlyContinue

if (-not $healthy) {
    $tail = @()
    foreach ($file in @($probeErr, $probeOut)) {
        if (Test-Path -LiteralPath $file) { $tail += (Get-Content -LiteralPath $file -Tail 20) }
    }
    throw "The staged sidecar never answered /health, so the installer would ship an app that cannot start. Its output was:`n$($tail -join [Environment]::NewLine)"
}
Write-Host "    sidecar booted on port $probePort and answered /health"

$stagedBytes = (Get-ChildItem -LiteralPath $StageDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ("    staged size: {0:N1} MB" -f ($stagedBytes / 1MB))

# ---- the installer -------------------------------------------------------

if ($SkipInstaller) {
    Write-Host ''
    Write-Host "Stopped after staging, as asked. The layout is at $StageDir"
    return
}

Write-Step 'Compiling the installer'
$iscc = Find-Iscc
if (-not $iscc) {
    throw "Inno Setup's compiler was not found. Install it with: winget install JRSoftware.InnoSetup"
}
Write-Host "    compiler: $iscc"
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
& $iscc $IssFile
Assert-ExitCode 'compiling the installer with ISCC'

$setup = Join-Path $DistDir "Sonore-Setup-$appVersion.exe"
if (-not (Test-Path -LiteralPath $setup)) {
    throw "ISCC reported success but $setup does not exist."
}

Write-Step "Built $setup"
Write-Host ("    size:   {0:N1} MB" -f ((Get-Item -LiteralPath $setup).Length / 1MB))
# Hashing through .NET rather than Get-FileHash: that cmdlet is absent on some
# Windows PowerShell 5.1 installations, and this script should not need it.
$sha256 = [BitConverter]::ToString(
    [Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($setup))
).Replace('-', '')
Write-Host "    sha256: $sha256"
Write-Host ''
Write-Host 'Run it by double-clicking it; it installs to C:\Program Files\Sonore and appears in Add or remove programs.'
