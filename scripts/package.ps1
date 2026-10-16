# Build a release of NanaType and package it.
#   pwsh scripts/package.ps1 [-Portable] [-SkipBuild]
# Needs: nana-packager on PATH (cargo install --path <NanaUI>/crates/nana-packager),
# Inno Setup 6 (iscc) for the installer. Packages are unsigned.
param([switch]$Portable, [switch]$SkipBuild)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$version = (Select-String -Path Cargo.toml -Pattern '^version = "(.+)"' | Select-Object -First 1).Matches.Groups[1].Value
if (-not $env:NANATYPE_BUILD_ID) { $env:NANATYPE_BUILD_ID = (git rev-parse --short HEAD) }
if (-not $SkipBuild) {
    $env:NANATYPE_REQUIRE_RESOURCES = "1"
    # Static C runtime: the package must not need the VC++ redistributable.
    $env:RUSTFLAGS = "-C target-feature=+crt-static"
    cargo build --locked --profile dist -p nanatype
}
$exe = Join-Path $root "target\dist\nanatype.exe"

# DX12 shader compiler shipped beside the exe (open-source DXC, see
# THIRD_PARTY_NOTICES.md). Set DXC_DLL to an official release's
# bin\x64\dxcompiler.dll; otherwise the Windows SDK copy is used.
$dxc = $env:DXC_DLL
if (-not $dxc) {
    $dxc = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\dxcompiler.dll" |
        Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
}
New-Item -ItemType Directory -Force (Join-Path $root "target\dxc") | Out-Null
Copy-Item $dxc (Join-Path $root "target\dxc\dxcompiler.dll") -Force

# Licences, staged in target\licenses for the installer and the zip: the
# notices (checked against Cargo.lock), each Rust crate's licence files, and
# a DXC release's own licence files (bin\x64\ -> two levels up).
$staged = Join-Path $root "target\licenses"
Remove-Item -Recurse -Force $staged -ErrorAction SilentlyContinue
pwsh (Join-Path $PSScriptRoot "third-party-notices.ps1") -Check -Texts $staged
if ($env:DXC_DLL) {
    $release = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $env:DXC_DLL))
    $dxcLicenses = Get-ChildItem (Join-Path $release "LICENSE*") -File -ErrorAction SilentlyContinue
    if (-not $dxcLicenses) { throw "No LICENSE* files in $release for the DXC release named by DXC_DLL" }
    New-Item -ItemType Directory -Force (Join-Path $staged "dxc") | Out-Null
    Copy-Item $dxcLicenses (Join-Path $staged "dxc")
}
# Outside target/: NanaUI treats executables under a cargo target dir as dev builds.
$out = Join-Path $root "dist"
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $out | Out-Null

$config = Join-Path $root "packaging\nana-package.toml"
if ($Portable) {
    $portable = Join-Path $out "nana-package.toml"
    (Get-Content $config) -replace 'backend = "installer"', 'backend = "portable"' | Set-Content $portable
    $config = $portable
}
nana-packager package --config $config --exe $exe --out $out --build-id $env:NANATYPE_BUILD_ID
$app = Join-Path $out "app\NanaType"
nana-packager validate $app --run

if ($Portable) {
    # The installer copies these itself (packaging/nanatype.iss); after
    # validation, as nana-packager does not know the folder.
    $licenses = Join-Path $app "licenses"
    New-Item -ItemType Directory -Force $licenses | Out-Null
    Copy-Item (Join-Path $root "crates\theme\fonts\*.LICENSE.txt") $licenses
    Copy-Item (Join-Path $root "packaging\licenses\*") $licenses
    Copy-Item (Join-Path $root "THIRD_PARTY_NOTICES.md") $licenses
    Copy-Item (Join-Path $staged "*") $licenses -Recurse
    Compress-Archive -Path (Join-Path $app "*") -DestinationPath (Join-Path $out "NanaType-$version-portable.zip")
} else {
    iscc "/DAppVersion=$version" "/DSourceDir=$app" "/DOutputDir=$out" (Join-Path $root "packaging\nanatype.iss")
}
Write-Host "Packaged NanaType $version into $out"
