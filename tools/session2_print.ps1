$ErrorActionPreference = 'Continue'
# session 2 注入打印：SYSTEM shell 里 GDI 打不开跨会话 Easy Print 重定向队列，
# 需经计划任务以持有重定向打印机的交互用户身份执行。日志路径基于脚本目录推导。
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $base 'session2_print.log'
"=== session2 print $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File $log -Encoding utf8
"session: $([System.Diagnostics.Process]::GetCurrentProcess().SessionId) user: $(whoami)" | Out-File $log -Append -Encoding utf8
try {
  $target = if ($env:KM118_PRINT_FILE) { $env:KM118_PRINT_FILE } else { Join-Path $base 'print_target.md' }
  $title = if ($env:KM118_PRINT_TITLE) { $env:KM118_PRINT_TITLE } else { 'KM-118 Print' }
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $base 'km_wrapper.ps1') -File $target -Title $title -AutoLong -ReversePages 2>&1
  $out | Out-File $log -Append -Encoding utf8
  "wrapper exit: $LASTEXITCODE" | Out-File $log -Append -Encoding utf8
} catch {
  "EXCEPTION: $_" | Out-File $log -Append -Encoding utf8
}
"=== job status ===" | Out-File $log -Append -Encoding utf8
Get-PrintJob -PrinterName 'KM-118*' -ErrorAction SilentlyContinue | Select-Object Id,DocumentName,JobStatus,TotalSize | Format-Table -AutoSize | Out-String | Out-File $log -Append -Encoding utf8
"=== done $(Get-Date -Format 'HH:mm:ss') ===" | Out-File $log -Append -Encoding utf8
