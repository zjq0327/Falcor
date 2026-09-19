param([switch]$VerifyOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$sdkRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$lock = Get-Content -LiteralPath (Join-Path $sdkRoot 'SDK.lock.json') -Raw | ConvertFrom-Json
foreach ($entry in $lock.files) {
    $target = [System.IO.Path]::GetFullPath((Join-Path $sdkRoot $entry.path))
    if (-not $target.StartsWith($sdkRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "SDK lock file contains an out-of-directory path: $($entry.path)"
    }
    $valid = (Test-Path -LiteralPath $target -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $entry.sha256)
    if (-not $valid -and -not $VerifyOnly) {
        New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($target)) | Out-Null
        Invoke-WebRequest -Uri $entry.url -OutFile $target
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
        (Get-Item -LiteralPath $target).Length -ne $entry.size -or
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $entry.sha256) {
        throw "NRC SDK hash/size verification failed: $($entry.path)"
    }
}
$signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $sdkRoot 'Bin/NRC_D3D12.dll')
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'NVIDIA Corporation') {
    throw "NRC D3D12 DLL signature did not verify as NVIDIA Corporation: $($signature.Status)"
}
Write-Output "Verified NVIDIA NRC $($lock.sdkVersion), commit $($lock.nrcCommit), matching RTXGI $($lock.rtxgiCommit)."
