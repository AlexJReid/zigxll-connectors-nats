# remove-old-clsid.ps1
# Removes the old NATS RTD CLSID and ProgID entries from HKCU

$oldClsid = "{A1B2C3D4-E5F6-7890-ABCD-EF0123456789}"
$progId   = "zigxll.connectors.nats"

$paths = @(
    "HKCU:\Software\Classes\CLSID\$oldClsid",
    "HKCU:\Software\Classes\$progId"
)

foreach ($p in $paths) {
    if (Test-Path $p) {
        Remove-Item -Path $p -Recurse -Force
        Write-Host "Removed: $p"
    } else {
        Write-Host "Not found (skipping): $p"
    }
}
