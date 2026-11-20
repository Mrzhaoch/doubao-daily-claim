# Ensure all *.ps1 in this folder are saved as UTF-8 WITH BOM.
# Windows PowerShell 5.1 needs the BOM to read Chinese text correctly;
# GitHub / git stores files without BOM, so run this once after downloading.
#
# Usage:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\restore-encoding.ps1

$ErrorActionPreference = 'Stop'

$bom = [byte[]](0xEF, 0xBB, 0xBF)
$files = Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File

foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
    if ($hasBom) {
        Write-Host ('[skip] ' + $f.Name + ' : already UTF-8 BOM')
        continue
    }
    $new = New-Object byte[] ($bytes.Length + 3)
    [Array]::Copy($bom, 0, $new, 0, 3)
    [Array]::Copy($bytes, 0, $new, 3, $bytes.Length)
    [System.IO.File]::WriteAllBytes($f.FullName, $new)
    Write-Host ('[fix ] ' + $f.Name + ' : BOM added')
}

Write-Host 'Done.'
