function Write-EnvironmentSummary {
  param(
    [parameter(Position = 0, ValueFromRemainingArguments)]
    [ValidateNotNullOrWhiteSpace()]
    [String]$State
  )
  Process {
    $Host.ui.WriteLine()
    Write-Heading "Build Environment Summary:`n"
    @(
      $(if ($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))) { "Project : $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))" })
      $(if ($State) { "State   : $State" })
      "Engine  : PowerShell $($PSVersionTable.PSVersion.ToString())"
      "Host OS : $(if($PSVersionTable.PSVersion.Major -le 5 -or $IsWindows){"Windows"}elseif($IsLinux){"Linux"}elseif($IsMacOS){"macOS"}else{"[UNKNOWN]"})"
      "PWD     : $PWD"
      "`n$((Get-ChildItem Env: | Where-Object {$_.Name -match "^(BUILD_|SYSTEM_|BH)"} | Sort-Object Name | Format-Table Name,Value -AutoSize | Out-String).Trim())"
    ) | Write-Host
  }
}