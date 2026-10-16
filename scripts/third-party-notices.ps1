# Regenerate the generated part of THIRD_PARTY_NOTICES.md: every Rust crate
# linked into the Windows build of nanatype.exe, grouped by licence, from
# `cargo metadata --locked` (downloads missing dependencies as needed). Also refreshes
# packaging/licenses/NotoSansSC-OFL.txt from the locked NanaUI checkout.
#
#   pwsh scripts/third-party-notices.ps1            # rewrite the files
#   pwsh scripts/third-party-notices.ps1 -Check     # fail if a crate has no
#                                                   # licence or a file is stale
#   pwsh scripts/third-party-notices.ps1 -Texts <dir>
#                                                   # also write <dir>/rust-crates.txt:
#                                                   # each crate's own licence files
#
# The output only depends on Cargo.lock and the crates' manifests, so two runs
# (on any machine) give the same bytes.
param([switch]$Check, [string]$Texts)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$notices = Join-Path $root "THIRD_PARTY_NOTICES.md"
$ofl = Join-Path $root "packaging\licenses\NotoSansSC-OFL.txt"
$begin = "<!-- BEGIN generated: scripts/third-party-notices.ps1 -->"
$end = "<!-- END generated -->"
$target = "x86_64-pc-windows-msvc"

# A normal build need not download every workspace/dev dependency that metadata
# resolves. Allow missing sources to be fetched, while keeping Cargo.lock fixed.
$json = cargo metadata --format-version 1 --locked --filter-platform $target --manifest-path (Join-Path $root "Cargo.toml")
if ($LASTEXITCODE -ne 0) { throw "cargo metadata failed" }
$meta = $json | ConvertFrom-Json -Depth 64
$packages = @{}
foreach ($p in $meta.packages) { $packages[$p.id] = $p }
$nodes = @{}
foreach ($n in $meta.resolve.nodes) { $nodes[$n.id] = $n }
$workspace = [System.Collections.Generic.HashSet[string]]::new([string[]]$meta.workspace_members)

# Everything nanatype reaches through normal dependencies: build scripts'
# and tests' dependencies are not linked into the program.
$app = $meta.workspace_members | Where-Object { $packages[$_].name -eq "nanatype" }
$seen = [System.Collections.Generic.HashSet[string]]::new()
$queue = [System.Collections.Generic.Queue[string]]::new()
$queue.Enqueue($app)
while ($queue.Count -gt 0) {
    $id = $queue.Dequeue()
    if (-not $seen.Add($id)) { continue }
    foreach ($d in $nodes[$id].deps) {
        if ($d.dep_kinds | Where-Object { $null -eq $_.kind }) { $queue.Enqueue($d.pkg) }
    }
}

function Repository($p) {
    if ($p.repository) { return $p.repository.TrimEnd("/") -replace "\.git$", "" }
    if ($p.source -like "git+*") { return ($p.source -replace "^git\+", "" -replace "[?#].*$", "") }
    if ($p.homepage) { return $p.homepage.TrimEnd("/") }
    return "https://crates.io/crates/$($p.name)"
}

# A plain choice ("MIT OR Apache-2.0") is written in one order, so the same
# choice is one group; anything with AND or parentheses stays as published.
function Normalize([string]$expr) {
    $expr = ($expr -replace "\s+", " ").Trim()
    if ($expr -match "[()]| AND | WITH ") { return $expr }
    $terms = [string[]]($expr -split " OR " | ForEach-Object { $_.Trim() })
    [System.Array]::Sort($terms, [System.StringComparer]::Ordinal)
    return $terms -join " OR "
}

$crates = foreach ($id in $seen) {
    if ($workspace.Contains($id)) { continue }
    $p = $packages[$id]
    $license = if ($p.license) { Normalize ($p.license -replace "/", " OR ") } else { $null }
    [pscustomobject]@{
        Name = $p.name; Version = $p.version; License = $license
        Repository = Repository $p; Dir = Split-Path -Parent $p.manifest_path
    }
}
$unlicensed = @($crates | Where-Object { -not $_.License })
if ($unlicensed.Count -gt 0) {
    $list = ($unlicensed | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ", "
    throw "No licence expression in Cargo metadata for: $list"
}

$ordinal = [System.StringComparer]::Ordinal
$sorted = [System.Collections.Generic.List[object]]::new()
# Two packages of one name and version (a registry copy and a git one) are
# listed once.
$listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($c in $crates) {
    if ($listed.Add("$($c.Name)|$($c.Version)|$($c.License)|$($c.Repository)")) { $sorted.Add($c) }
}
$sorted.Sort([System.Comparison[object]] {
    param($a, $b)
    $r = $ordinal.Compare($a.License, $b.License)
    if ($r -eq 0) { $r = $ordinal.Compare($a.Name, $b.Name) }
    if ($r -eq 0) { $r = $ordinal.Compare($a.Version, $b.Version) }
    $r
})

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add($begin)
$lines.Add("")
$lines.Add("## Rust crates")
$lines.Add("")
$lines.Add("The $($sorted.Count) crates below are compiled into ``nanatype.exe`` (Windows, ``$target``), as")
$lines.Add("locked in ``Cargo.lock``; NanaType's own crates are left out. Each crate's")
$lines.Add("licence files ship in the installer's ``licenses\rust-crates.txt``.")
$group = $null
foreach ($c in $sorted) {
    if ($c.License -cne $group) {
        $group = $c.License
        $n = @($sorted | Where-Object { $_.License -ceq $group }).Count
        $lines.Add("")
        $lines.Add("### $group ($n)")
        $lines.Add("")
    }
    $lines.Add("- $($c.Name) $($c.Version) — <$($c.Repository)>")
}
$lines.Add("")
$lines.Add($end)
$generated = $lines -join "`n"

$current = [System.IO.File]::ReadAllText($notices) -replace "`r`n", "`n"
$at = $current.IndexOf($begin)
$stop = $current.IndexOf($end)
if ($at -lt 0 -or $stop -lt $at) { throw "THIRD_PARTY_NOTICES.md has no generated section markers" }
$updated = $current.Substring(0, $at) + $generated + $current.Substring($stop + $end.Length)

# NanaUI's Noto Sans SC licence, from the checkout Cargo.lock names.
$nanaUi = $sorted | Where-Object { $_.Name -eq "nana-ui" } | Select-Object -First 1
if (-not $nanaUi) { throw "nana-ui is not a dependency" }
$oflSource = Join-Path $nanaUi.Dir "assets\fonts\OFL.txt"
if (-not (Test-Path $oflSource)) { throw "Missing $oflSource" }
$oflText = [System.IO.File]::ReadAllText($oflSource) -replace "`r`n", "`n"

$utf8 = [System.Text.UTF8Encoding]::new($false)
if ($Check) {
    $stale = @()
    if ($updated -cne $current) { $stale += "THIRD_PARTY_NOTICES.md" }
    $have = if (Test-Path $ofl) { [System.IO.File]::ReadAllText($ofl) -replace "`r`n", "`n" } else { "" }
    if ($oflText -cne $have) { $stale += "packaging/licenses/NotoSansSC-OFL.txt" }
    if ($stale.Count -gt 0) {
        throw "Out of date: $($stale -join ', '). Run pwsh scripts/third-party-notices.ps1"
    }
    Write-Host "Third-party notices are up to date ($($sorted.Count) crates, all licensed)."
} else {
    [System.IO.File]::WriteAllText($notices, $updated, $utf8)
    New-Item -ItemType Directory -Force (Split-Path -Parent $ofl) | Out-Null
    [System.IO.File]::WriteAllText($ofl, $oflText, $utf8)
    Write-Host "Wrote THIRD_PARTY_NOTICES.md ($($sorted.Count) crates) and $ofl"
}

if ($Texts) {
    # Each crate's licence files as published, identical texts written once
    # with every crate that ships them.
    $byText = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    $byName = [System.Collections.Generic.List[object]]::new($sorted)
    $byName.Sort([System.Comparison[object]] {
        param($a, $b)
        $r = $ordinal.Compare($a.Name, $b.Name)
        if ($r -eq 0) { $r = $ordinal.Compare($a.Version, $b.Version) }
        $r
    })
    foreach ($c in $byName) {
        $files = Get-ChildItem -LiteralPath $c.Dir -File |
            Where-Object { $_.Name -match '^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|UNLICENSE)' } |
            Sort-Object -Property { [string]::Join(',', [int[]][char[]]$_.Name) }
        if (-not $files) {
            $key = "(no licence file in the package; licence expression: $($c.License))"
            if (-not $byText.Contains($key)) { $byText[$key] = [System.Collections.Generic.List[string]]::new() }
            $byText[$key].Add("$($c.Name) $($c.Version)")
            continue
        }
        foreach ($f in $files) {
            $text = ([System.IO.File]::ReadAllText($f.FullName) -replace "`r`n", "`n").Trim()
            if (-not $byText.Contains($text)) { $byText[$text] = [System.Collections.Generic.List[string]]::new() }
            $byText[$text].Add("$($c.Name) $($c.Version) ($($f.Name))")
        }
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("Licence files of the Rust crates compiled into NanaType ($target).")
    $out.Add("Generated by scripts/third-party-notices.ps1 from Cargo.lock.")
    foreach ($text in $byText.Keys) {
        $out.Add("")
        $out.Add(("=" * 78))
        $out.Add("Used by: " + ($byText[$text] -join ", "))
        $out.Add(("-" * 78))
        $out.Add($text)
    }
    New-Item -ItemType Directory -Force $Texts | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Texts "rust-crates.txt"), ($out -join "`n") + "`n", $utf8)
    Write-Host "Wrote $(Join-Path $Texts 'rust-crates.txt') ($($byText.Count) distinct texts)"
}
