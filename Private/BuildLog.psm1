using namespace System.IO
using namespace System.Management.Automation

# .SYNOPSIS
#  BuildLog — static build-log utilities, replaces the six loose .ps1 helpers:
#  Get-Elapsed, Write-BuildLog, Write-Heading, Write-EnvironmentSummary,
#  Write-TerminatingError, Invoke-CommandWithLog.
# .NOTES
#  Uses [AnsiConsole] from cliHelper.core when available; falls back to Write-Host.
class BuildLog {

  # ── Elapsed time ────────────────────────────────────────────────────────────
  # Replaces: Get-Elapsed
  static [string] GetElapsed() {
    $buildstart = [System.Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildStart')
    $build_date = if ([string]::IsNullOrWhiteSpace($buildstart)) { Get-Date } else { Get-Date $buildstart }
    $elapse_msg = if ([bool][int]$env:IsCI) {
      "[ + $(((Get-Date) - $build_date).ToString())]"
    } else {
      "[$((Get-Date).ToString("HH:mm:ss")) + $(((Get-Date) - $build_date).ToString())]"
    }
    return "$elapse_msg{0}" -f (' ' * (30 - $elapse_msg.Length))
  }

  # ── Core log writer ─────────────────────────────────────────────────────────
  # Replaces: Write-BuildLog (all parameter combinations)
  static [void] Write([object]$Message) {
    [BuildLog]::_Write($Message, $false, $false, $false, $false)
  }
  static [void] WriteCmd([object]$Message) {
    [BuildLog]::_Write($Message, $true, $false, $false, $false)
  }
  static [void] WriteWarning([object]$Message) {
    [BuildLog]::_Write($Message, $false, $true, $false, $false)
  }
  static [void] WriteSevere([object]$Message) {
    [BuildLog]::_Write($Message, $false, $false, $true, $false)
  }
  static [void] WriteClean([object]$Message) {
    [BuildLog]::_Write($Message, $false, $false, $false, $true)
  }

  # Main write implementation
  static hidden [void] _Write([object]$Message, [bool]$Cmd, [bool]$Warning, [bool]$Severe, [bool]$Clean) {
    $fg = switch ($true) {
      $Severe { 'Red'; break }
      $Warning { 'Yellow'; break }
      $Cmd { 'Magenta'; break }
      default { if ((Get-Host).UI.RawUI.ForegroundColor -eq 'Gray') { 'White' } else { 'Gray' } }
    }
    $prefix = switch ($true) {
      $Severe { '##[Error]   '; break }
      $Warning { '##[Warning] '; break }
      $Cmd { '##[Command] '; break }
      default { '##[Info]    ' }
    }
    $date = [BuildLog]::GetElapsed() + ' '
    $lines = if ($Clean) {
      "$Message" -split "[\r\n]" | Where-Object { $_ } | ForEach-Object { $prefix + $_ }
    } elseif ($Cmd) {
      $i = 0
      "$Message" -split "[\r\n]" | Where-Object { $_ } | ForEach-Object {
        $tag = if ($i -eq 0) { 'PS > ' } else { '  >> ' }; $i++
        $prefix + $date + $tag + $_
      }
    } else {
      "$Message" -split "[\r\n]" | Where-Object { $_ } | ForEach-Object { $prefix + $date + $_ }
    }
    $text = $lines -join "`n"
    # Try AnsiConsole (cliHelper.core); fall back to Write-Host
    try {
      $ansiColor = switch ($fg) {
        'Red' { 'red' }
        'Yellow' { 'yellow' }
        'Magenta' { 'magenta' }
        default { 'grey' }
      }
      $safe = [AnsiConsole]::EscapeMarkup($text)
      [AnsiConsole]::Console.MarkupLine("[$ansiColor]$safe[/]")
    } catch {
      Write-Host -ForegroundColor $fg $text
    }
  }

  # ── Section heading ──────────────────────────────────────────────────────────
  # Replaces: Write-Heading
  static [void] WriteHeading([string]$Title) {
    [void][BuildLog]::WriteHeading($Title, $false)
  }
  static [string] WriteHeading([string]$Title, [bool]$Passthru) {
    $msg = "`n##[section] $([BuildLog]::GetElapsed()) $Title"
    if ($Passthru) { return $msg }
    try {
      $safe = [AnsiConsole]::EscapeMarkup($msg)
      [AnsiConsole]::Console.MarkupLine("[bold green]$safe[/]")
    } catch {
      Write-Host $msg -ForegroundColor Green
    }
    return [string]::Empty
  }

  # ── Environment summary ──────────────────────────────────────────────────────
  # Replaces: Write-EnvironmentSummary
  static [void] WriteEnvironmentSummary([string]$State) {
    [BuildLog]::WriteHeading("Build Environment Summary:`n")
    $lines = @(
      $(if ([System.Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')) {
          "Project : $([System.Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))"
        })
      $(if (![string]::IsNullOrWhiteSpace($State)) { "State   : $State" })
      "Engine  : PowerShell $((Get-Variable PSVersionTable).Value.PSVersion)"
      "Host OS : $(if ((Get-Variable PSVersionTable).Value.PSVersion.Major -le 5 -or (Get-Variable IsWindows).Value) { 'Windows' } elseif ((Get-Variable IsLinux).Value) { 'Linux' } elseif ((Get-Variable IsMacOS).Value) { 'macOS' } else { '[UNKNOWN]' })"
      "PWD     : $PWD"
      "`n$((Get-ChildItem Env: | Where-Object { $_.Name -match '^(BUILD_|SYSTEM_|BH)' } | Sort-Object Name | Format-Table Name, Value -AutoSize | Out-String).Trim())"
    ) | Where-Object { $_ }
    try {
      $c = [AnsiConsole]::Console
      foreach ($l in $lines) {
        $c.MarkupLine("[cyan]$([AnsiConsole]::EscapeMarkup($l))[/]")
      }
    } catch {
      $lines | Write-Host
    }
  }

  # ── Terminating error ────────────────────────────────────────────────────────
  # Replaces: Write-TerminatingError
  static [void] WriteTerminatingError(
    [PSCmdlet]$Caller,
    [string]$ExceptionName,
    [string]$ExceptionMessage,
    [object]$ExceptionObject,
    [string]$ErrorId,
    [System.Management.Automation.ErrorCategory]$ErrorCategory
  ) {
    $exception = New-Object $ExceptionName $ExceptionMessage
    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
      $exception, $ErrorId, $ErrorCategory, $ExceptionObject
    )
    if ($null -eq $Caller) {
      throw $errorRecord
    } else {
      $Caller.ThrowTerminatingError($errorRecord)
    }
  }

  # ── Command invocation with logging ─────────────────────────────────────────
  # Replaces: Invoke-CommandWithLog
  static [object[]] InvokeCommandWithLog([scriptblock]$ScriptBlock) {
    [BuildLog]::WriteCmd($ScriptBlock.ToString() -join "`n")
    return $ScriptBlock.Invoke()
  }
}