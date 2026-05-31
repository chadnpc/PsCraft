# PsCraft Refactor Plan

> **Goal:** Flatten the nesting-loop crash, migrate all Private buildlog helpers into `BuildLog` static methods, delegate heavy public-cmdlet logic into Private classes, and wire in `cliHelper.core` console features (ANSI, FigletText, Progress, Status, ThreadRunner, prompts, Tree rendering, etc.) to replace every `Write-Host` call.

---

## 1. Root Cause — Module Nesting Limit

### What is happening

PowerShell limits `using module` nesting to **10 levels**. The current chain is:

```
PsCraft.psm1
 └─ using module Private\ModuleManager.psm1      ← level 1
     └─ using module Private\PsModule.psm1       ← level 2
         └─ using module Private\ModuleManager.psm1  ← CIRCULAR → level 3 → … → 10 → CRASH
```

**Concrete circular chain:**

| File | `using module` references |
|------|--------------------------|
| `PsCraft.psm1` | `BuildLog`, `Enums`, `Models`, `ModuleManager`, `PsModule`, `PsModuleData` |
| `ModuleManager.psm1` | `PsModule.psm1`, `Models.psm1` |
| `PsModule.psm1` | `Enums.psm1`, `PsModuleData.psm1`, `ModuleManager.psm1` (re-imports!) |
| `PsModuleData.psm1` | *(no `using module` currently — safe leaf)* |
| `BuildLog.psm1` | `Enums.psm1` |

`PsModule.psm1` importing `ModuleManager.psm1` while `ModuleManager.psm1` imports `PsModule.psm1` creates the cycle. PowerShell follows each `using module` statement at parse-time and re-enters the chain until it hits depth 10.

### Fix: Flatten the dependency graph

**Rule:** Every `.psm1` in `Private\` becomes a **self-contained** class file. No private submodule may `using module` another private submodule. All inter-class linkage happens exclusively in **`PsCraft.psm1`** (the root loader), which already declares all `using module` statements in the correct topological order.

**Required order in `PsCraft.psm1`:**

```powershell
# Layer 0 – no deps
using module Private\Enums.psm1

# Layer 1 – depends only on Enums (referenced via root PsCraft.psm1)
using module Private\BuildLog.psm1
using module Private\Models.psm1
using module Private\PsModuleData.psm1

# Layer 2 – depends on Models, Enums
using module Private\ModuleManager.psm1

# Layer 3 – depends on Enums, PsModuleData, ModuleManager
using module Private\PsModule.psm1
```

**Edits per file:**

| File | Remove these `using module` lines |
|------|----------------------------------|
| `Private\BuildLog.psm1` | `using module .\Enums.psm1` |
| `Private\Models.psm1` | `using module .\Enums.psm1` |
| `Private\PsModuleData.psm1` | *(none currently — keep clean)* |
| `Private\ModuleManager.psm1` | `using module .\PsModule.psm1`, `using module .\Models.psm1` |
| `Private\PsModule.psm1` | `using module .\Enums.psm1`, `using module .\PsModuleData.psm1`, `using module .\ModuleManager.psm1` |

> [!IMPORTANT]
> Also remove the `#Requires -Modules PsModuleBase, PsCraft` line from `PsCraft.psm1` — a module cannot require itself.

---

## 2. BuildLog — Migrate from Cmdlets to Static Methods

### Current state

Six loose `.ps1` helper functions dot-sourced at runtime:

| File | Function |
|------|----------|
| `Private\Get-Elapsed.ps1` | `Get-Elapsed` |
| `Private\Write-BuildLog.ps1` | `Write-BuildLog` |
| `Private\Write-Heading.ps1` | `Write-Heading` |
| `Private\Write-EnvironmentSummary.ps1` | `Write-EnvironmentSummary` |
| `Private\Write-TerminatingError.ps1` | `Write-TerminatingError` |
| `Private\Invoke-CommandWithLog.ps1` | `Invoke-CommandWithLog` |

The `BuildLog` class in `Private\BuildLog.psm1` already declares stub static methods for all six — they just have empty bodies.

### Target state

`BuildLog.psm1` becomes the **single source of truth** for all build logging. The six `.ps1` helper files are **deleted**. Public cmdlets call `[BuildLog]::` static methods instead of the old functions. `Write-Host` is replaced with `[AnsiConsole]::Console` writes (with fallback).

### Full implementation of `BuildLog.psm1`

```powershell
using namespace System
using namespace System.IO
using namespace System.Management.Automation

class BuildLog {
  # ── Elapsed time ──────────────────────────────────────────────────────────
  static [string] GetElapsed() {
    $buildstart = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildStart')
    $build_date = if ([string]::IsNullOrWhiteSpace($buildstart)) { Get-Date } else { Get-Date $buildstart }
    $elapse_msg = if ([bool][int]$env:IsCI) {
      "[ + $(((Get-Date) - $build_date).ToString())]"
    } else {
      "[$((Get-Date).ToString("HH:mm:ss")) + $(((Get-Date) - $build_date).ToString())]"
    }
    return "$elapse_msg{0}" -f (' ' * (30 - $elapse_msg.Length))
  }

  # ── Core build log writer (replaces Write-BuildLog) ───────────────────────
  static [void] Write([object]$Message)            { [BuildLog]::Write($Message, $false, $false, $false, $false) }
  static [void] WriteCmd([object]$Message)         { [BuildLog]::Write($Message, $true, $false, $false, $false) }
  static [void] WriteWarning([object]$Message)     { [BuildLog]::Write($Message, $false, $true, $false, $false) }
  static [void] WriteSevere([object]$Message)      { [BuildLog]::Write($Message, $false, $false, $true, $false) }
  static [void] WriteClean([object]$Message)       { [BuildLog]::Write($Message, $false, $false, $false, $true) }

  static [void] Write([object]$Message, [bool]$Cmd, [bool]$Warning, [bool]$Severe, [bool]$Clean) {
    ($fg, $prefix) = switch ($true) {
      $Severe  { 'Red',     '##[Error]   '; break }
      $Warning { 'Yellow',  '##[Warning] '; break }
      $Cmd     { 'Magenta', '##[Command] '; break }
      default  { ($(if ($Host.UI.RawUI.ForegroundColor -eq 'Gray') { 'White' } else { 'Gray' }), '##[Info]    ') }
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
    try {
      $c = [AnsiConsole]::Console
      switch ($fg) {
        'Red'     { $c.MarkupLine("[red]$([AnsiConsole]::EscapeMarkup($text))[/]") }
        'Yellow'  { $c.MarkupLine("[yellow]$([AnsiConsole]::EscapeMarkup($text))[/]") }
        'Magenta' { $c.MarkupLine("[magenta]$([AnsiConsole]::EscapeMarkup($text))[/]") }
        default   { $c.MarkupLine("[grey]$([AnsiConsole]::EscapeMarkup($text))[/]") }
      }
    } catch {
      Write-Host -ForegroundColor $fg $text
    }
  }

  # ── Section heading (replaces Write-Heading) ──────────────────────────────
  static [void] WriteHeading([string]$Title) { [BuildLog]::WriteHeading($Title, $false) }
  static [string] WriteHeading([string]$Title, [bool]$Passthru) {
    $msg = "`n##[section] $([BuildLog]::GetElapsed()) $Title"
    if ($Passthru) { return $msg }
    try {
      [AnsiConsole]::Console.MarkupLine("[bold green]$([AnsiConsole]::EscapeMarkup($msg))[/]")
    } catch {
      Write-Host $msg -ForegroundColor Green
    }
    return [string]::Empty
  }

  # ── Environment summary (replaces Write-EnvironmentSummary) ───────────────
  static [void] WriteEnvironmentSummary([string]$State) {
    [BuildLog]::WriteHeading("Build Environment Summary:`n")
    $lines = @(
      $(if ([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')) { "Project : $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))" })
      $(if (![string]::IsNullOrWhiteSpace($State)) { "State   : $State" })
      "Engine  : PowerShell $($PSVersionTable.PSVersion)"
      "Host OS : $(if ($PSVersionTable.PSVersion.Major -le 5 -or $IsWindows) { 'Windows' } elseif ($IsLinux) { 'Linux' } elseif ($IsMacOS) { 'macOS' } else { '[UNKNOWN]' })"
      "PWD     : $PWD"
      "`n$((Get-ChildItem Env: | Where-Object { $_.Name -match '^(BUILD_|SYSTEM_|BH)' } | Sort-Object Name | Format-Table Name, Value -AutoSize | Out-String).Trim())"
    ) | Where-Object { $_ }
    try {
      $c = [AnsiConsole]::Console
      foreach ($l in $lines) { $c.MarkupLine("[cyan]$([AnsiConsole]::EscapeMarkup($l))[/]") }
    } catch { $lines | Write-Host }
  }

  # ── Terminating error (replaces Write-TerminatingError) ───────────────────
  static [void] WriteTerminatingError(
    [PSCmdlet]$Caller,
    [string]$ExceptionName,
    [string]$ExceptionMessage,
    [object]$ExceptionObject,
    [string]$ErrorId,
    [System.Management.Automation.ErrorCategory]$ErrorCategory
  ) {
    $exception   = New-Object $ExceptionName $ExceptionMessage
    $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, $ErrorId, $ErrorCategory, $ExceptionObject)
    if ($null -eq $Caller) { throw $errorRecord } else { $Caller.ThrowTerminatingError($errorRecord) }
  }

  # ── Command invocation with logging (replaces Invoke-CommandWithLog) ──────
  static [object[]] InvokeCommandWithLog([scriptblock]$ScriptBlock) {
    [BuildLog]::WriteCmd($ScriptBlock.ToString() -join "`n")
    return $ScriptBlock.Invoke()
  }
}
```

### Files to delete after implementing BuildLog

- `Private\Get-Elapsed.ps1`
- `Private\Write-BuildLog.ps1`
- `Private\Write-Heading.ps1`
- `Private\Write-EnvironmentSummary.ps1`
- `Private\Write-TerminatingError.ps1`
- `Private\Invoke-CommandWithLog.ps1`

### Call-site replacements in public cmdlets

| Old call | New call |
|----------|----------|
| `Get-Elapsed` | `[BuildLog]::GetElapsed()` |
| `Write-BuildLog "msg"` | `[BuildLog]::Write("msg")` |
| `Write-BuildLog -Cmd "msg"` | `[BuildLog]::WriteCmd("msg")` |
| `Write-BuildLog -Warning "msg"` | `[BuildLog]::WriteWarning("msg")` |
| `Write-BuildLog -Severe "msg"` | `[BuildLog]::WriteSevere("msg")` |
| `Write-BuildLog -Clean "msg"` | `[BuildLog]::WriteClean("msg")` |
| `Write-Heading "title"` | `[BuildLog]::WriteHeading("title")` |
| `Write-EnvironmentSummary "state"` | `[BuildLog]::WriteEnvironmentSummary("state")` |
| `Write-TerminatingError ...` | `[BuildLog]::WriteTerminatingError(...)` |
| `Invoke-CommandWithLog { ... }` | `[BuildLog]::InvokeCommandWithLog({ ... })` |

---

## 3. Public Cmdlet Delegation — Move Logic into Classes

### 3.1  `Build-Module.ps1` → `BuildOrchestrator` class

`Build-Module` is 606 lines. The cmdlet should be a thin wrapper that:
1. Parses parameters
2. Creates a `[BuildOrchestrator]` instance
3. Calls the appropriate method

**New file: `Private\BuildOrchestrator.psm1`**

```powershell
class BuildOrchestrator : ModuleManager {
  [string[]] $TaskList
  [string]   $Path
  [string[]] $RequiredModules

  BuildOrchestrator([string]$path, [string[]]$tasks, [string[]]$requiredModules) { ... }

  static [void] ShowBanner() {
    # FigletText "PsCraft" banner via cliHelper.core
    try {
      $fig = [FigletText]::new([FigletFont]"DEFAULT_3D", 'PsCraft')
      [AnsiConsole]::Console.Write($fig)
    } catch { Write-Host "=== PsCraft ===" -ForegroundColor Cyan }
  }

  [void]   PreparePackageFeeds()        { ... }  # nuget/psgallery bootstrap
  [void]   ResolveBuildRequirements()   { ... }  # install/import modules with Status spinner
  [int]    RunClean()                   { ... }  # deletes BuildOutput
  [int]    RunCompile()                 { ... }  # copies files, updates manifest (with Progress bar)
  [int]    RunTest()                    { ... }  # invokes Test-Module.ps1 via Pester
  [int]    RunDeploy()                  { ... }  # bumps version, publishes (with ConfirmationPrompt)
  [void]   Finalize([bool]$success)     { ... }  # local repo + env cleanup

  [int] Run([string[]]$tasks) {
    foreach ($t in $tasks) {
      switch ($t) {
        'Clean'   { $this.RunClean()   }
        'Compile' { $this.RunCompile() }
        'Test'    { $this.RunTest()    }
        'Deploy'  { $this.RunDeploy()  }
      }
    }
    return 0
  }
}
```

**`Public\Build-Module.ps1` after refactor (~80 lines):**

```powershell
function Build-Module {
  [cmdletbinding(DefaultParameterSetName = 'task')]
  param( ... )   # identical params as today
  begin {
    [BuildOrchestrator]::ShowBanner()
    $orchestrator = [BuildOrchestrator]::new($Path, $Task, $RequiredModules)
    $orchestrator.PreparePackageFeeds()
    $orchestrator.ResolveBuildRequirements()
  }
  process {
    if ($Help.IsPresent) { $orchestrator.ShowHelp(); return }
    $exitCode = $orchestrator.Run($Task)
  }
  end { return $exitCode }
}
```

### 3.2  `Set-BuildVariables.ps1` → delegate to `ModuleManager` static method

Extract the 12 `Set-Env` calls into `[ModuleManager]::SetBuildVariables([string]$Path, [string]$Prefix, [PsObject]$Data)`. The cmdlet becomes a ~20-line param-parsing wrapper that calls `[ModuleManager]::SetBuildVariables(...)`.

### 3.3  `New-PsModule.ps1` — trim and delegate tree display

The module-creation logic already lives in `[PsModule]::Create()`. The tree display in line 110 already calls `cliHelper.core\Show-Tree` — replace the conditional `tree` shell call with a direct `[Tree]` class render using `cliHelper.core`.

---

## 4. cliHelper.core Integration

### Available features (from `ConsoleHelper` demo methods)

| cliHelper.core Type | Use in PsCraft |
|--------------------|-|
| `[AnsiConsole]::Console` | Replace every `Write-Host` / `$Host.UI.WriteLine()` |
| `[FigletText]` + `[FigletFont]` | `Build-Module` banner ("PsCraft") |
| `[Progress]` / `[ProgressContext]` | Compile step file-copy loop |
| `[Status]` / `[StatusContext]` | Long waits: dependency resolution, PSGallery ping |
| `[ThreadRunner]::Run(...)` | Parallel module installs in `ResolveBuildRequirements` |
| `[Tree]` / `[TreeNode]` | `New-PsModule` directory tree display |
| `[ConfirmationPrompt]` | `Build-Module -Task Deploy` — "Deploy to PSGallery?" prompt |
| `[SelectionPrompt]` | Future: interactive task picker |
| `[BarChart]` | Post-build summary: file count, test pass/fail |
| `[Table]` | `Build-Module -Help` task list |
| `[Panel]` + `[Rule]` | Section separators |
| `[Markup]` | Inline rich text in `[BuildLog]::Write()` |

### Key integration patterns

**Status spinner for long operations:**

```powershell
$status = [Status]::new([AnsiConsole]::Console.GetWriter())
$status.Start("Resolving dependencies...", [Action[StatusContext]] {
    param($ctx)
    foreach ($mod in $this.RequiredModules) {
        $ctx.Update("Installing $mod ...")
        Install-Module -Name $mod -Verbose:$false -ea Stop
    }
})
```

**Progress bar for file copy (Compile step):**

```powershell
$progress = [Progress]::new([AnsiConsole]::Console)
$progress.Start([Action[ProgressContext]] {
    param($ctx)
    $task = $ctx.AddTask('[green]Copying module files[/]', [ProgressTaskSettings]::new())
    $task.MaxValue = $filesToCopy.Count
    foreach ($f in $filesToCopy) {
        Copy-Item -Recurse -Path $f -Destination $outputDir
        $task.Increment(1)
    }
})
```

**Figlet banner in `BuildOrchestrator::ShowBanner()`:**

```powershell
$fig = [FigletText]::new([FigletFont]"DEFAULT_3D", 'PsCraft')
[AnsiConsole]::Console.Write($fig)
```

### Specific `Write-Host` replacements in `Build-Module.ps1`

| Current code | Replace with |
|---|---|
| `Write-EnvironmentSummary "..."` | `[BuildLog]::WriteEnvironmentSummary("...")` |
| `Write-Heading "..."` | `[BuildLog]::WriteHeading("...")` |
| `Write-BuildLog "..."` | `[BuildLog]::Write("...")` |
| `$Host.UI.WriteLine()` | `[AnsiConsole]::Console.WriteLine("")` |
| `Write-Host -f Green "..."` | `[AnsiConsole]::Console.MarkupLine("[green]...[/]")` |
| `Write-Host -f Yellow "..."` | `[AnsiConsole]::Console.MarkupLine("[yellow]...[/]")` |
| `$buildrequirements.ForEach({ Import-Module $_ })` | `[ThreadRunner]::Run("Installing", ...)` |
| `Get-ChildItem $outputModVerDir \| Format-Table` | `[Table]` via `[AnsiConsole]` |
| `Get-PSakeScriptTasks \| Format-Table` | Rich `[Table]` with Name/Description/DependsOn |

---

## 5. Updated Module Loading Order in `PsCraft.psm1`

```powershell
#!/usr/bin/env pwsh
using namespace System.IO
using namespace System.ComponentModel
using namespace System.Collections.Generic
using namespace System.Collections.ObjectModel
using namespace System.Management.Automation.Language

# ── Private submodules (topological order, zero circular deps) ──────────
using module Private\Enums.psm1              # Layer 0: no deps
using module Private\BuildLog.psm1           # Layer 1
using module Private\Models.psm1             # Layer 1
using module Private\PsModuleData.psm1       # Layer 1
using module Private\ModuleManager.psm1      # Layer 2
using module Private\PsModule.psm1           # Layer 3
using module Private\BuildOrchestrator.psm1  # Layer 4: cliHelper.core types
```

> [!NOTE]
> Remove `#Requires -Modules PsModuleBase, PsCraft` from `PsCraft.psm1`. `PsModuleBase` should be declared in `PsCraft.psd1 → RequiredModules`, not in the `.psm1`.

---

## 6. File-by-File Change Summary

```
Private\
  Enums.psm1                    KEEP     — Already clean leaf
  BuildLog.psm1                 REWRITE  — Implement all 6 static methods with AnsiConsole
  Models.psm1                   MODIFY   — Remove `using module .\Enums.psm1`
  PsModuleData.psm1             KEEP     — Already a clean leaf
  ModuleManager.psm1            MODIFY   — Remove `using module .\PsModule.psm1` and `.\Models.psm1`
  PsModule.psm1                 MODIFY   — Remove all three `using module` lines
  BuildOrchestrator.psm1        CREATE   — New class extracted from Build-Module.ps1
  Get-Elapsed.ps1               DELETE
  Write-BuildLog.ps1            DELETE
  Write-Heading.ps1             DELETE
  Write-EnvironmentSummary.ps1  DELETE
  Write-TerminatingError.ps1    DELETE
  Invoke-CommandWithLog.ps1     DELETE

Public\
  Build-Module.ps1              REFACTOR — Thin wrapper → BuildOrchestrator (~80 lines)
  New-PsModule.ps1              REFACTOR — Trim, use [Tree] for dir display
  Set-BuildVariables.ps1        REFACTOR — Delegate to [ModuleManager]::SetBuildVariables()

PsCraft.psm1                    MODIFY   — Fix using module order, remove self-require, add BuildOrchestrator
PsCraft.psd1                    MODIFY   — Add cliHelper.core@0.3.2 to RequiredModules, add BuildOrchestrator to NestedModules
```

---

## 7. Implementation Order (Phases)

| Phase | Tasks | Risk |
|-------|-------|------|
| **Phase 1** | Fix nesting loop — remove circular `using module` in private files, fix `PsCraft.psm1` header | 🟢 Low — pure refactor, no logic changes |
| **Phase 2** | Implement `BuildLog` static methods, delete 6 `.ps1` helper files, update all call sites | 🟡 Medium — ~25 call sites across 3 public cmdlets |
| **Phase 3** | Create `BuildOrchestrator.psm1`, extract `Build-Module` body into it | 🟡 Medium — large function, test thoroughly |
| **Phase 4** | Integrate `[AnsiConsole]`, `[FigletText]`, `[Progress]`, `[Status]`, `[ThreadRunner]` | 🟡 Medium — requires `cliHelper.core` to be imported |
| **Phase 5** | Refactor `New-PsModule` and `Set-BuildVariables` cmdlets | 🟢 Low |
| **Phase 6** | Update `PsCraft.psd1` `RequiredModules`/`NestedModules`, update `$typestoExport` | 🟢 Low |
| **Phase 7** | Update `Tests\` to cover new class methods | 🟢 Low |

---

## 8. Open Questions for Review

1. **`PsModuleBase`** — Is the `PsModuleBase` module installed/available? Several classes inherit from it (`PsCraft : PsModuleBase, ModuleManager`). Its source is not in this repo. Where is it?
2. **PSake retention** — `Build-Module` uses `Invoke-Psake`. Should `BuildOrchestrator` keep PSake as a task runner, or replace it with a native class-based task graph? Removing PSake removes one required module.
3. **`BuildOrchestrator` naming** — Alternatively `PsCraftBuilder` to align with the root class name. Preference?
4. **`New-PsModule` `#Requires -RunAsAdministrator`** — This is inside a `begin {}` block, which is invalid in PowerShell. Should it be removed, or moved to the function's top?
5. **`Build-Module`'s `Install-Dotnet`** — The `[TypeName]` parameter type on line 444 is undefined. Delete the entire inner function or fix before Phase 3?
6. **`cliHelper.core` version pinning** — `0.3.2` is installed. Should `RequiredModules` pin the exact version or use `MinimumVersion`?
