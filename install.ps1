$ErrorActionPreference = "Stop"

$Repo = "vmvarela/ztd"
$Version = if ($env:ZTD_VERSION) { $env:ZTD_VERSION } else { "latest" }
$InstallDir = if ($env:ZTD_INSTALL_DIR) { $env:ZTD_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "ztd\bin" }

if ($Version -eq "latest") {
    $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
    $Version = $release.tag_name
    if (-not $Version) { throw "ztd: could not resolve latest release" }
}

$arch = $env:PROCESSOR_ARCHITECTURE
switch ($arch) {
    "AMD64" { $asset = "ztd-x86_64-windows.exe" }
    "ARM64" { $asset = "ztd-aarch64-windows.exe" }
    "x86" { $asset = "ztd-x86-windows.exe" }
    default { throw "ztd: unsupported Windows architecture: $arch" }
}

$url = "https://github.com/$Repo/releases/download/$Version"
$tmp = Join-Path $env:TEMP ("ztd-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    Write-Host "ztd: downloading $asset $Version"
    Invoke-WebRequest "$url/$asset" -OutFile (Join-Path $tmp $asset)
    Invoke-WebRequest "$url/sha256sums.txt" -OutFile (Join-Path $tmp "sha256sums.txt")

    $expected = (Get-Content (Join-Path $tmp "sha256sums.txt") |
        Where-Object { $_ -match "\s$([regex]::Escape($asset))$" } |
        ForEach-Object { ($_ -split "\s+")[0] } | Select-Object -First 1)
    if (-not $expected) { throw "ztd: checksum not found for $asset" }
    $actual = (Get-FileHash (Join-Path $tmp $asset) -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) { throw "ztd: checksum mismatch" }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item (Join-Path $tmp $asset) (Join-Path $InstallDir "ztd.exe") -Force
    Write-Host "ztd: installed $(Join-Path $InstallDir 'ztd.exe')"

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($userPath -split ";") -notcontains $InstallDir) {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
        Write-Host "ztd: added $InstallDir to the user PATH"
    }
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
