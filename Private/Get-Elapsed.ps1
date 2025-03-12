function Get-Elapsed {
  $buildstart = [Environment]::GetEnvironmentVariable($ENV:RUN_ID + 'BuildStart')
  $build_date = if ([string]::IsNullOrWhiteSpace($buildstart)) { Get-Date }else { Get-Date $buildstart }
  $elapse_msg = if ([bool][int]$env:IsCI) {
    "[ + $(((Get-Date) - $build_date).ToString())]"
  } else {
    "[$((Get-Date).ToString("HH:mm:ss")) + $(((Get-Date) - $build_date).ToString())]"
  }
  "$elapse_msg{0}" -f (' ' * (30 - $elapse_msg.Length))
}