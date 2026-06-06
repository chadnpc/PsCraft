## [![cliHelper.logger](docs/images/logging.png)](https://www.PowerShellgallery.com/packages/cliHelper.logger)

A thread-safe, in-memory and file-based logging module for PowerShell.

[![Downloads](https://img.shields.io/powershellgallery/dt/cliHelper.logger.svg?style=flat&logo=powershell&color=blue)](https://www.PowerShellgallery.com/packages/cliHelper.logger)

## Installation

```PowerShell
Install-Module cliHelper.logger
```

## Usage demo

Get started:

  1. In an interactive pwsh session

      ```PowerShell
      Import-Module cliHelper.logger
      ```
      or

  2. In your script? Add:

      ```PowerShell
      #Requires -Modules cliHelper.logger, othermodulename...
      ```

Then

```PowerShell
# 1. usage in an object
$demo = [PsCustomObject]@{
  PsTypeName  = "cliHelper.logger.demo"
  Description = "Shows how a logger instance is used with cmdlets"
  Version     = [Version]'0.1.2'
  Logger      = New-Logger -Level 1
}
$demo.PsObject.Methods.Add([psscriptmethod]::new('SimulateCommand', {
      Param(
        [Parameter(Mandatory = $true)]
        [validateset('Success', 'Failing')]
        [string]$type
      )

      If($type -eq 'Success') {
        $this.Logger.LogInfoLine("Getting username ...")
        [Threading.Thread]::Sleep(2000);
        $this.Logger.LogInfoLine("Done.")
        return [IO.Path]::Join(
          [Environment]::UserDomainName,
          [Environment]::UserName
        )
      }
      $file = "C:\fake-dir{0}\NonExistentFile.txt" -f (Get-Random -Max 100000000).ToString("D9")
      try {
        $this.Logger.LogInfoLine("Getting $file ...")
        [Threading.Thread]::Sleep(1000);
        Get-Item $file -ea Stop
        $this.Logger.LogInfoLine("Done!")
      } catch {
        $this.Logger | Write-LogEntry -l Error -m "Failed to access $([IO.Path]::GetFileName($file))" -e $_.Exception
      }
    }
  )
)
# 2. You can also save logs to json files
$demo.Logger | Add-JsonAppender

$demo.Logger.set_default() # (OPTIONAL) handy only when you are in a pwsh terminal.

# Now u don't have to pipe $demo.Logger each time u write or read logs in this session:
try {
  $logPath = [string][Logger]::Default.logdir
  Write-LogEntry -Level INFO -Message "app started in directory: $logPath"
  # same as:
  $demo.Logger.LogInfoLine("app st4rt3d in d1r3ct0ry: $logPath")

  Write-LogEntry -Level Debug -Message "Configuration loaded." # Note: this logline will be skipped!
  # ie: in this case anything below level 1 (INFO) won't be recorded, since [int]$demo.Logger.MinLevel -eq 1

  #  Name value
  #  ---- -----
  # DEBUG     0
  #  INFO     1
  #  WARN     2
  # ERROR     3
  # FATAL     4
  # - that means, only DEBUG lines won't show in logs
  # - Table from command: [LogLevel[]][Enum]::GetNames[LogLevel]() | % { [PsCustomObject]@{ Name = $_ ; value = $_.value__ } }

  # 3. success command
  $user = $demo.SimulateCommand("Success")
  Write-LogEntry -Level INFO -Message "Processing request for user: $user"

  # 4. Failing command
  $demo.SimulateCommand("Failing")
  Write-LogEntry -Level 2 -Message "Operation completed with warnings."
  Write-LogEntry -Message "Logs saved in $logPath"
} finally {
  Read-LogEntries -Type Json # same as: $demo.Logger.ReadEntries(@{ type = "json" })
  # 5. IMPORTANT: Dispose the logger to flush buffers and release file handles
  # $demo.Logger.Dispose()
}
```

Read the docs for In-depth Usage examples

#### NOTES:

1. Remeber to **dispose** the object

    Because appenders (especially file-based ones) hold resources, you **must** call `$logger.Dispose()` when you are finished logging to ensure logs are flushed and files are closed properly.

    Use a `try...finally` block to ensure its always called.

    Failure to call `.Dispose()` can lead to:
      *   Log messages not being written to files (still stuck in buffers).
      *   File locks being held, preventing other processes (or even later runs of your script) from accessing the log files.

## In-depth Usage examples:

*   **Logger (`[Logger]`)**: The main object you interact with. It holds configuration (like `MinLevel`) and a list of appenders. **Crucially, it should be disposed of when done (`$logger.Dispose()`)**.
*   **Appenders (`[LogAppender]`)**: Define *where* log messages go. This module includes:
    *   `[ConsoleAppender]`: Writes colored output to the PowerShell host.
    *   `[FileAppender]`: Writes formatted text to a specified file.
    *   `[JsonAppender]`: Writes JSON objects (one per line) to a specified file.
    You add instances of these to the logger's `$logger._appenders` list.
*   **Severity Levels (`[LogLevel]`)**: Define the importance of a message (Debug, Info, Warn, Error, Fatal). The logger's `MinLevel` filters messages below that level.


## **Usage examples**

- `I. With Cmdlets`

  ```PowerShell
  try {
    $logger = [IO.Path]::Combine([IO.Path]::GetTempPath(), "MyAppLogs") | New-Logger
    $logger | Add-JsonAppender
    $logger | Write-LogEntry -level Info -Message "Added JSON appender.
    Logs now go to Console, `$env:TMP/MyAppLog/*{guid-filename}.log, and .json"
    $logger.LogInfoLine("This message goes to all appenders.") # Direct call
  } finally {
    $logger.ReadEntries(@{ type = "JSON" })
    $logger.Dispose()
  }
  ```

- `II. With no cmdlets`

  For more control or when building your own modules/tools, you can use the classes directly.

  ```PowerShell
  # Import the module to make classes available
  Import-Module cliHelper.logger

  try {
    $Logdir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "MyAppLogs")
    $logger = [Logger]::new($Logdir)
    $logger.MinLevel = [LogLevel]::Debug

    # Create and add appenders manually
    $logger.AddLogAppender([ConsoleAppender]@{})
    $logger.AddLogAppender([FileAppender]"$Logdir/mytool.log")
    $logger.AddLogAppender([JsonAppender]"$Logdir/mytool_metrics.json")

    $logger.LogInfoLine("Object Logger Initialized. with $($logger.Session.LogAppenders.Count) appenders.")
    $logger.Debug("Detailed trace message.")
    # simulated failure:
    throw [System.IO.FileNotFoundException]::new("Required config file missing", "config.xml")
  } catch {
    $logger.LogFatalLine(("{0} :`n  {1}" -f $_.FullyQualifiedErrorId, $_.ScriptStackTrace), $_.Exception)
  } finally {
    $logger.LogInfoLine("Check logs in $($logger.LogFiles)")
    $logger.Dispose()
  }
  ```

  ### You can also use your custom classes.

  ```PowerShell
  # .SYNPOSIS
  # A custom classes inheriting `LogEntry`
  # adds more structured data to logs.
  #.EXAMPLE
  # [CustomEntry]@{}
  class CustomEntry : LogEntry {
    [string]$CorrelationId # Custom field

    # Factory methods (required pattern)
    static [CustomEntry] Create([LogLevel]$severity, [string]$message) {
      return [CustomEntry]::Create($severity, $message, $null)
    }
    static [CustomEntry] Create([LogLevel]$severity, [string]$message, [Exception]$exception) {
      # Example: generate or retrieve CorrelationId
      $Id = (Get-Random -Maximum 10000).ToString("D5")
      return [CustomEntry]@{
        Severity      = $severity
        Message       = $message
        Exception     = $exception
        CorrelationId = $Id
      }
    }
  }

  # then:
  try {
    $logger = [Logger]::new()
    $logger.LogType = [CustomEntry]
    $logger.LogInfoLine("Logging event with custom entry type.")
    $logger.LogInfoLine("By default, If no LogAppender is added, Logs will only show in the console (like this).")
  } finally {
    $logger.Dispose()
  }
  $logger.LogInfoLine("Trying to log something else...")
  # this should throw an error:
  # OperationStopped: Cannot access a disposed object.
  # Object name: 'ConsoleAppender is already disposed'.
  ```
