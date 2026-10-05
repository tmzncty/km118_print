$ErrorActionPreference = 'Continue'
$log = 'C:\Users\Administrator\.lux\km118\batch_print.log'
$queue = Get-Content 'C:\Users\Administrator\.lux\km118\print_queue.txt' -Encoding UTF8
"=== batch print start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') — $($queue.Count) items ===" | Out-File $log -Encoding utf8
foreach ($file in $queue) {
  $file = $file.Trim()
  if (-not $file) { continue }
  $title = [System.IO.Path]::GetFileNameWithoutExtension($file)
  ">>> $title : $(Get-Date -Format 'HH:mm:ss')" | Out-File $log -Append -Encoding utf8
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\Users\Administrator\.lux\km118\km_wrapper.ps1' -File $file -Title $title -AutoLong -ReversePages 2>&1
    $out | Out-File $log -Append -Encoding utf8
    "    exit: $LASTEXITCODE" | Out-File $log -Append -Encoding utf8
  } catch {
    "    EXCEPTION: $_" | Out-File $log -Append -Encoding utf8
  }
  Start-Sleep -Seconds 6
}
"=== batch done $(Get-Date -Format 'HH:mm:ss') ===" | Out-File $log -Append -Encoding utf8
