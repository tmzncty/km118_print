$ErrorActionPreference = 'Continue'
$log = 'C:\Users\Administrator\.lux\km118\session2_print.log'
"=== session2 print $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File $log -Encoding utf8
"session: $([System.Diagnostics.Process]::GetCurrentProcess().SessionId) user: $(whoami)" | Out-File $log -Append -Encoding utf8
try {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\Users\Administrator\.lux\km118\km_wrapper.ps1' -File 'C:\Users\Administrator\.lux\km118\print_ready\KE_E4_vocab.md' -Title 'KE-E4 Vocabulary' -AutoLong -ReversePages 2>&1
  $out | Out-File $log -Append -Encoding utf8
  "wrapper exit: $LASTEXITCODE" | Out-File $log -Append -Encoding utf8
} catch {
  "EXCEPTION: $_" | Out-File $log -Append -Encoding utf8
}
"=== job status ===" | Out-File $log -Append -Encoding utf8
Get-PrintJob -PrinterName 'KM-118*' -ErrorAction SilentlyContinue | Select-Object Id,DocumentName,JobStatus,TotalSize | Format-Table -AutoSize | Out-String | Out-File $log -Append -Encoding utf8
"=== done $(Get-Date -Format 'HH:mm:ss') ===" | Out-File $log -Append -Encoding utf8
