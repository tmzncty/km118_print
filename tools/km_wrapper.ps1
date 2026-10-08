param(
  [string]$File,
  [string]$Text,
  [string]$Title = "KM-118 Print",
  [int]$LongHeightMm = 0,
  [switch]$AutoLong,
  [switch]$ReversePages,
  [switch]$ListOnly
)
$ErrorActionPreference = 'Stop'
$p = Get-Printer | Where-Object { $_.Name -like 'KM-118*' } | Select-Object -First 1
if (-not $p) { Write-Error "No KM-118 printer found in local queue"; exit 1 }
Write-Host ("Resolved printer: " + $p.Name + " port=" + $p.PortName + " driver=" + $p.DriverName)
if ($ListOnly) { exit 0 }

$script = Join-Path $PSScriptRoot 'km118_receipt_print.ps1'
$params = @{ Title = $Title; PrinterName = $p.Name; LongHeightMm = $LongHeightMm }
if ($File) { $params.File = $File }
elseif ($Text) { $params.Text = $Text }
if ($ReversePages) { $params.ReversePages = $true }
if ($AutoLong) { $params.AutoLong = $true }
& $script @params
