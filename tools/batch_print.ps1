$ErrorActionPreference = 'Continue'
# 批量打印：读队列文件逐册打印。路径基于脚本所在目录推导，无硬编码用户路径。
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $base 'batch_print.log'
$queueFile = Join-Path $base 'print_queue.txt'
if (-not (Test-Path $queueFile)) { Write-Error "queue file not found: $queueFile"; exit 1 }
$queue = Get-Content $queueFile -Encoding UTF8
"=== batch print start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') — $($queue.Count) items ===" | Out-File $log -Encoding utf8
foreach ($file in $queue) {
  $file = $file.Trim()
  if (-not $file) { continue }
  $title = [System.IO.Path]::GetFileNameWithoutExtension($file)
  ">>> $title : $(Get-Date -Format 'HH:mm:ss')" | Out-File $log -Append -Encoding utf8
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $base 'km_wrapper.ps1') -File $file -Title $title -AutoLong -ReversePages 2>&1
    $out | Out-File $log -Append -Encoding utf8
    "    exit: $LASTEXITCODE" | Out-File $log -Append -Encoding utf8
  } catch {
    "    EXCEPTION: $_" | Out-File $log -Append -Encoding utf8
  }
  Start-Sleep -Seconds 6
}
"=== batch done $(Get-Date -Format 'HH:mm:ss') ===" | Out-File $log -Append -Encoding utf8
