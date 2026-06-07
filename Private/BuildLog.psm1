#!/usr/bin/env pwsh
using namespace System.IO
using namespace System.Text

# BuildLogEntry is a standalone record type for build-correlated diagnostics.
# NOTE: Cannot inherit from LogEntry (cliHelper.logger type) here because
#       class base-types must be resolvable at parse time via 'using module'.
#       The _logger.LogType assignment is commented out accordingly.
class BuildLogEntry {
  [string]$TaskName
  [string]$ProjectName
  [string]$BuildRunId
  [string]$Severity
  [string]$Message
  [Exception]$Exception

  static [BuildLogEntry] Create([string]$severity, [string]$message) {
    return [BuildLogEntry]::Create($severity, $message, $null)
  }
  static [BuildLogEntry] Create([string]$severity, [string]$message, [Exception]$exception) {
    return [BuildLogEntry]@{
      Severity    = $severity
      Message     = $message
      Exception   = $exception
      TaskName    = ''
      ProjectName = ''
      BuildRunId  = ''
    }
  }
}


class BuildTaskResult {
  [string]$Name
  [bool]$Success
  [timespan]$Duration
  [string]$Message

  BuildTaskResult([string]$Name) {
    $this.Init($Name, $false, [timespan]::Zero)
  }

  BuildTaskResult([string]$Name, [bool]$Success, [timespan]$Duration) {
    $this.Init($Name, $Success, $Duration)
  }

  hidden [void] Init([string]$Name, [bool]$Success, [timespan]$Duration) {
    $this.Name = $Name
    $this.Success = $Success
    $this.Duration = $Duration
    $this.Message = ''
  }
}

class TestResult {
  [int]$Total
  [int]$Passed
  [int]$Failed
  [int]$Skipped
  [string]$Duration

  TestResult() {
    $this.Init(0, 0, 0, 0)
  }

  TestResult([int]$Total, [int]$Passed, [int]$Failed, [int]$Skipped) {
    $this.Init($Total, $Passed, $Failed, $Skipped)
  }

  hidden [void] Init([int]$Total, [int]$Passed, [int]$Failed, [int]$Skipped) {
    $this.Total = $Total
    $this.Passed = $Passed
    $this.Failed = $Failed
    $this.Skipped = $Skipped
    $this.Duration = '0s'
  }
}


#  BuildLog — static build-log utilities, replaces the six loose .ps1 helpers:
#  Get-Elapsed, Write-BuildLog, Write-Heading, Write-EnvironmentSummary,
#  Write-TerminatingError, Invoke-CommandWithLog.
# .NOTES
#  Uses [AnsiConsole] from cliHelper.core when available; falls back to Write-Host.
class BuildLog {
  static [string] GetElapsed() {
    $buildstart = [System.Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildStart')
    $build_date = if ([string]::IsNullOrWhiteSpace($buildstart)) { Get-Date } else { Get-Date $buildstart }
    $elapse_msg = if ([bool][int]$env:IsCI) {
      "𓉘 + $(((Get-Date) - $build_date).ToString())𓉝"
    } else {
      "𓉘$((Get-Date).ToString("HH:mm:ss")) + $(((Get-Date) - $build_date).ToString())𓉝"
    }
    return "$elapse_msg$(' ' * [Math]::Abs((30 - $elapse_msg.Length)))"
  }

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

  static [void] WriteStatus([string]$Message) {
    [BuildLog]::WriteStatus($Message, 'info')
  }
  static [void] WriteStatus([string]$Message, [string]$Level) {
    $color = switch ($Level.ToLower()) {
      'success' { 'green'; break }
      'warning' { 'yellow'; break }
      'error' { 'red'; break }
      'command' { 'magenta3'; break }
      default {
        # info and any other unresolved level
        'cyan1'
      }
    }
    try {
      [AnsiConsole]::Console.MarkupLine("[$color]$Message[/]")
      return
    } catch {
      Write-Host "$($_ | Format-List * -Force | Out-String)" -f Yellow
      Write-Host $Message
    }
  }

  static [void] WriteStep([string]$Message) {
    [BuildLog]::WriteStatus("[bold]•[/] $Message", 'info')
  }

  # Main write implementation
  static hidden [void] _Write([object]$Message, [bool]$Cmd, [bool]$Warning, [bool]$Severe, [bool]$Clean) {
    $color = switch ($true) {
      $Severe { 'Red'; break }
      $Warning { 'Yellow'; break }
      $Cmd { 'Magent3'; break }
      default { if ((Get-Host).UI.RawUI.ForegroundColor -eq 'Gray') { 'White' } else { 'Gray' } }
    }
    $prefix = switch ($true) {
      $Severe { 'ERROR   '; break }
      $Warning { 'WARNING '; break }
      $Cmd { 'COMMAND '; break }
      default { 'INFO    ' }
    }
    $date = if ($Clean) { '' } else { [BuildLog]::GetElapsed() + ' ' }
    $i = 0
    $lines = "$Message" -split "[\r\n]" | Where-Object { $_ } | ForEach-Object {
      $tag = if ($Cmd) { if ($i -eq 0) { 'PS > ' } else { '  >> ' } } else { '' }
      $i++
      $date + $tag + $_
    }
    $text = $lines -join "`n"
    $text_lines = $text.Split("`n")

    # two cases: single line or multi line, and in both cases, markup could fail rendering.
    # i.e: sometimes markup just fails when there are unescaped '[' or ']'
    if ($text_lines.Count -gt 1) {
      $l1 = $prefix + " " + $text_lines[0]
      $l2 = $text_lines[1..($text_lines.Count - 1)] -join "`n"
      [AnsiConsole]::Console.Markup("[$color]$l1[/]")
      [AnsiConsole]::Console.Write("`n$l2`n")
      try {
        [AnsiConsole]::Console.Markup("[$color]$l1[/]")
        [AnsiConsole]::Console.Write("`n$l2`n")
      } catch {
        Write-Host "$($_ | Format-List * -Force | Out-String)" -f Red
        [AnsiConsole]::Console.Write("$l1")
        [AnsiConsole]::Console.Write("`n$l2`n")
      }
    } else {
      try {
        [AnsiConsole]::Console.Markup("[$color]$prefix $text[/]")
      } catch {
        Write-Host "$($_ | Format-List * -Force | Out-String)" -f Red
        [AnsiConsole]::Console.Write("$prefix $text")
      }
    }
  }

  static [void] WriteHeading([string]$Title) {
    [void][BuildLog]::WriteHeading($Title, $false)
  }
  static [string] WriteHeading([string]$Title, [bool]$Passthru) {
    $msg = "$Title"
    if ($Passthru) { return $msg }
    try {
      $rule = [Rule]::new($msg)
      $rule.Justification = 'Left'
      [AnsiConsole]::Console.Write($rule)
    } catch {
      Write-Host "$($_ | Format-List * -Force | Out-String)" -f Yellow
      $elapsed = [BuildLog]::GetElapsed()
      [BuildLog]::WriteStatus("$elapsed $Title", 'success')
    }
    return [string]::Empty
  }

  static [void] WriteBanner([string]$Title = 'PsCraft') {
    try {
      $fig = [FigletText]::new([FigletFont]'DEFAULT_3D', $Title)
      [AnsiConsole]::Console.Write($fig)
    } catch {
      Write-Host "$($_ | Format-List * -Force | Out-String)" -f Yellow
      [BuildLog]::WriteStatus("=== $Title ===", 'info')
    }
  }

  static [void] WriteEnvironmentSummary([string]$State) {
    $projectName = [System.Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
    $buildNumber = [System.Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildNumber')
    $buildOutput = [System.Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput')
    $projectPath = [System.Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectPath')
    $engineVersion = (Get-Variable PSVersionTable -ValueOnly).PSVersion
    $hostOS = if ((Get-Variable PSVersionTable -ValueOnly).PSVersion.Major -le 5 -or (Get-Variable IsWindows -ValueOnly)) { 'Windows' } elseif ((Get-Variable IsLinux -ValueOnly)) { 'Linux' } elseif ((Get-Variable IsMacOS -ValueOnly)) { 'macOS' } else { '[UNKNOWN]' }

    try {
      $grid = [Grid]::new()
      $grid.AddColumn() | Out-Null
      $grid.AddColumn() | Out-Null
      [void]$grid.AddRow(@(
          [Markup]::new('[bold cyan1]Project[/]'),
          [Markup]::new($($projectName ?? '[grey]Unknown[/]'))
        ))
      [void]$grid.AddRow(@(
          [Markup]::new('[bold cyan1]State[/]'),
          [Markup]::new($($State ?? '[grey]N/A[/]'))
        ))
      [void]$grid.AddRow(@(
          [Markup]::new('[bold cyan1]Build Number[/]'),
          [Markup]::new($($buildNumber ?? '[grey]N/A[/]'))
        ))
      [void]$grid.AddRow(@(
          [Markup]::new('[bold cyan1]Engine[/]'),
          [Markup]::new($("PowerShell $engineVersion"))
        ))
      [void]$grid.AddRow(@(
          [Markup]::new('[bold cyan1]Host OS[/]'),
          [Markup]::new($($hostOS))
        ))
      [void]$grid.AddRow(@(
          [Markup]::new('[bold cyan1]Project Path[/]'),
          [Markup]::new($($projectPath ?? '[grey]Unknown[/]'))
        ))
      [void]$grid.AddRow(@(
          [Markup]::new('[bold cyan1]Build Output[/]'),
          [Markup]::new($($buildOutput ?? '[grey]Unknown[/]'))
        ))

      $panel = [Panel]::new($grid)
      $panel.Header = [PanelHeader]::new('Build Environment Summary')
      [AnsiConsole]::Console.Write($panel)

      $envVars = Get-ChildItem Env: | Where-Object { $_.Name -match '^(BUILD_|SYSTEM_|BH)' } | Sort-Object Name | ForEach-Object {
        "$($_.Name): $($_.Value)"
      }
      if ($envVars.Count -gt 0) {
        $varsText = [string]::Join("`n", $envVars)
        $varsPanel = [Panel]::new([Markup]::new($varsText))
        $varsPanel.Header = [PanelHeader]::new('Selected Environment Variables')
        [AnsiConsole]::Console.Write($varsPanel)
      }
    } catch {
      Write-Host "$($_ | Format-List * -Force | Out-String)" -f Yellow
      [BuildLog]::WriteHeading('Build Environment Summary')
      if ($projectName) { [BuildLog]::WriteStatus("Project : $projectName", 'info') }
      if (![string]::IsNullOrWhiteSpace($State)) { [BuildLog]::WriteStatus("State   : $State", 'info') }
      [BuildLog]::WriteStatus("Engine  : PowerShell $engineVersion", 'info')
      [BuildLog]::WriteStatus("Host OS : $hostOS", 'info')
      [BuildLog]::WriteStatus("PWD     : $PWD", 'info')
      Get-ChildItem Env: | Where-Object { $_.Name -match '^(BUILD_|SYSTEM_|BH)' } | Sort-Object Name | Format-Table Name, Value -AutoSize
    }
  }

  static [void] WriteTerminatingError(
    [System.Management.Automation.PSCmdlet]$Caller,
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

  static [object[]] InvokeCommandWithLog([scriptblock]$ScriptBlock) {
    try {
      $commandText = $ScriptBlock.ToString() -join "`n"
      [AnsiConsole]::Console.MarkupLine("[magenta3][bold]PS > [/][/][grey]$commandText[/]")
    } catch {
      Write-Host "$($_ | Format-List * -Force | Out-String)" -f Yellow
      [BuildLog]::WriteCmd($ScriptBlock.ToString() -join "`n")
    }
    return $ScriptBlock.Invoke()
  }
}

class BuildSummary {
  [string]$ProjectName
  [string]$BuildNumber
  [datetime]$StartTime
  [datetime]$EndTime
  [System.Collections.Generic.List[psobject]]$Tasks
  [TestResult]$TestResults
  [bool]$Success

  static [hashtable[]] $MemberDefinitions = @(
    @{
      MemberType = 'ScriptProperty'
      MemberName = 'TotalDuration'
      Value      = { return $this.EndTime - $this.StartTime }
    }
  )

  static BuildSummary() {
    foreach ($d in [BuildSummary]::MemberDefinitions) {
      # Update-TypeData -TypeName ([BuildSummary].Name) @d -ErrorAction Ignore
    }
  }

  BuildSummary([string]$ProjectName, [string]$BuildNumber) {
    $this.Init($ProjectName, $BuildNumber)
  }

  hidden [void] Init([string]$ProjectName, [string]$BuildNumber) {
    $this.ProjectName = $ProjectName
    $this.BuildNumber = $BuildNumber
    $this.StartTime = [datetime]::Now
    $this.EndTime = [datetime]::Now
    $this.Tasks = [System.Collections.Generic.List[psobject]]::new()
    $this.TestResults = [TestResult]::new()
    $this.Success = $true
  }

  [void] AddTask([string]$Name, [bool]$Success, [timespan]$Duration) {
    $task = [BuildTaskResult]::new($Name, $Success, $Duration)
    $this.Tasks.Add($task)
    if (!$Success) { $this.Success = $false }
  }

  [void] SetTestResults([int]$Total, [int]$Passed, [int]$Failed, [int]$Skipped) {
    $this.TestResults = [TestResult]::new($Total, $Passed, $Failed, $Skipped)
    if ($Failed -gt 0) { $this.Success = $false }
  }

  [void] RenderSummary() {
    $this.EndTime = [datetime]::Now
    $totalDuration = $this.TotalDuration

    try {
      # Try to render with BreakdownChart if available
      $table = [Table]::new()
      [void]$table.AddColumn([TableColumn]::new('Task'))
      [void]$table.AddColumn([TableColumn]::new('Status'))
      [void]$table.AddColumn([TableColumn]::new('Duration'))

      foreach ($task in $this.Tasks) {
        $status = if ($task.Success) { '[green]✓ Pass[/]' } else { '[red]✗ Fail[/]' }
        $duration = $task.Duration.ToString('mm\:ss')
        [void]$table.AddRow(@($task.Name, $status, $duration))
      }

      # Add test results row if available
      if ($this.TestResults.Total -gt 0) {
        $testStatus = if ($this.TestResults.Failed -eq 0) { '[green]✓ Pass[/]' } else { '[red]✗ Fail[/]' }
        $testStr = "$($this.TestResults.Passed)/$($this.TestResults.Total) passed"
        if ($this.TestResults.Failed -gt 0) { $testStr += ", $($this.TestResults.Failed) failed" }
        [void]$table.AddRow(@('Tests', $testStatus, $testStr))
      }

      $panel = [Panel]::new($table)
      $panel.Header = [PanelHeader]::new("Build Summary - $($this.ProjectName) v$($this.BuildNumber)")
      $status = if ($this.Success) { '[green]SUCCESS[/]' } else { '[red]FAILED[/]' }
      $panel.Footer = [PanelHeader]::new("$status | Total: $($totalDuration.ToString('mm\:ss'))")
      [AnsiConsole]::Console.Write($panel)

      # Render test breakdown chart if tests ran
      if ($this.TestResults.Total -gt 0) {
        try {
          $chart = [BreakdownChart]::new()
          $chart.Width = 40
          if ($this.TestResults.Passed -gt 0) {
            $chart.AddItem('[green]Passed[/]', $this.TestResults.Passed, [Color]::Green)
          }
          if ($this.TestResults.Failed -gt 0) {
            $chart.AddItem('[red]Failed[/]', $this.TestResults.Failed, [Color]::Red)
          }
          if ($this.TestResults.Skipped -gt 0) {
            $chart.AddItem('[yellow]Skipped[/]', $this.TestResults.Skipped, [Color]::Yellow)
          }
          [AnsiConsole]::Console.Write($chart)
        } catch {
          Write-Warning "Chart rendering failed! $($_ | Format-List * -Force | Out-String)"
          # Chart rendering failed, just show text summary
          [BuildLog]::WriteStatus("Test Results: $($this.TestResults.Passed) passed, $($this.TestResults.Failed) failed, $($this.TestResults.Skipped) skipped", 'default')
        }
      }
    } catch {
      Write-Host "$($_ | Format-List * -Force | Out-String)" -f Yellow
      # Fallback to simple text output
      [BuildLog]::WriteHeading("Build Summary - $($this.ProjectName) v$($this.BuildNumber)")
      foreach ($task in $this.Tasks) {
        $status = if ($task.Success) { 'PASS' } else { 'FAIL' }
        [BuildLog]::WriteStatus("$($task.Name): $status ($($task.Duration.ToString('mm\:ss')))", $(if ($task.Success) { 'success' } else { 'error' }))
      }
      if ($this.TestResults.Total -gt 0) {
        [BuildLog]::WriteStatus("Tests: $($this.TestResults.Passed)/$($this.TestResults.Total) passed", $(if ($this.TestResults.Failed -eq 0) { 'success' } else { 'error' }))
      }
    }
  }
}
