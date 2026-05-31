#!/usr/bin/env pwsh
using namespace System.IO
using namespace System.Net
using namespace System.ComponentModel
using namespace System.Collections.Generic
using namespace System.Collections.ObjectModel
using namespace System.Management.Automation
using namespace System.Management.Automation.Language

#Requires -Psedition Core

using module Private\Enums.psm1
using module Private\Models.psm1
using module Private\BuildLog.psm1
using module Private\PsCraft.psm1

#region    PsCraft
# .SYNOPSIS
#  PsCraft: the module builder and manager.
# .EXAMPLE
#  [PsModule]$module = New-PsModule "MyModule"   # Creates a new module named "MyModule" in $pwd
#  $builder = [PsCraft]::new($module.Path)
# .EXAMPLE
# $handler = [PsCraft]::new("MyModule", "Path/To/MyModule.psm1")
# if ($handler.TestModulePath()) {
#    $handler.ImportModule()
#    $functions = $handler.ListExportedFunctions()
#    Write-Host "Exported functions: $functions"
#  } else {
#    Write-Host "Module not found at specified path"
#  }
#  TODO: Add more robust example. (This shit can do way much more.)

class PsCraft : PsModuleBase, Microsoft.PowerShell.Commands.ModuleCmdletBase {
  [ValidateNotNullOrWhiteSpace()][string]$ModuleName
  [ValidateNotNullOrWhiteSpace()][string]$BuildOutputPath # $RootPath/BouldOutput/$ModuleName
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$RootPath # Module Project root
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$TestsPath
  [ValidateNotNullOrEmpty()][version]$ModuleVersion
  [ValidateNotNullOrEmpty()][FileInfo]$dataFile # ..strings.psd1
  [ValidateNotNullOrEmpty()][FileInfo]$buildFile
  static [IO.DirectoryInfo]$LocalPSRepo
  static [PsObject]$LocalizedData
  static [PSCmdlet]$CallerCmdlet
  static [bool]$Useverbose
  [List[string]]$TaskList

  PsCraft() {}
  PsCraft([string]$RootPath) { [void][PsCraft]::From($RootPath, $this) }
  static [PsCraft] Create() { return [PsCraft]::From((Resolve-Path .).Path, $null) }
  static [PsCraft] Create([string]$RootPath) { return [PsCraft]::From($RootPath, $null) }

  [bool] ImportModule([string]$path) {
    try {
      $m = Import-Module -Name $path -Force -PassThru
      if ($m) { $m.PsObject.Properties.Name.ForEach({ $this.$($_) = $m.$($_) }) }
      return $?
    } catch {
      Write-Error "Failed to import module: $_"
      return $false
    }
  }
  static [LocalPsModule[]] Search([string]$Name) {
    [ValidateNotNullOrWhiteSpace()][string]$Name = $Name
    $res = @(); $AvailModls = Get-Module -ListAvailable -Name $Name -Verbose:$false -ErrorAction Ignore
    if ($null -ne $AvailModls) {
      foreach ($m in ($AvailModls.ModuleBase -as [string[]])) {
        if ($null -eq $m) {
          $res += [PsCraft]::FindLocalPsModule($Name, 'LocalMachine', $null); continue
        }
        if ([IO.Directory]::Exists($m)) {
          $res += [PsCraft]::FindLocalPsModule($Name, [IO.DirectoryInfo]::New($m))
        }
      }
    }
    return $res
  }
  static [Net.SecurityProtocolType] GetSecurityProtocol() {
    $p = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::SystemDefault
    if ([Net.SecurityProtocolType].GetMember("Tls12").Count -gt 0) { $p = $p -bor [Net.SecurityProtocolType]::Tls12 }
    return $p
  }
  static [PSCustomObject] FormatCode([PsModule]$module) {
    [int]$errorCount = 0
    [int]$maxRetries = 5
    $results = [PSCustomObject]@{
      Analysis = [List[PSCustomObject]]@()
      Errors   = [List[PSCustomObject]]@()
    }
    if (![IO.Directory]::Exists($module.Path.FullName)) {
      Write-Warning "Module path '$($module.Path.FullName)' does not exist. Please run `$module.save() first."
      return $results
    }
    $filesToCheck = $module.Files.Value.Where({ $_.Extension -in ('.ps1', '.psd1', '.psm1') })
    $frmtSettings = $module.Files.Where({ $_.Name -eq "ScriptAnalyzer" })[0].Value.FullName
    if ($filesToCheck.Count -eq 0) {
      Write-Host "No files to format found in the module!" -ForegroundColor Green
      return $results
    }
    if (!$frmtSettings) {
      Write-Warning "ScriptAnalyzer Settings not found in the module!"
      return $results
    }
    foreach ($file in $filesToCheck) {
      for ($i = 0; $i -lt $maxRetries; $i++) {
        try {
          $_rcontent = Get-Content -Path $file.FullName -Raw
          $formatted = Invoke-Formatter -ScriptDefinition $_rcontent -Settings $frmtSettings -Verbose:$false
          $formatted | Set-Content -Path $file.FullName -NoNewline
          $_analysis = Invoke-ScriptAnalyzer -Path $file.FullName -Settings $frmtSettings -ErrorAction Stop
          if ($null -ne $_analysis) { $errorCount++; [void]$results.Analysis.Add(($_analysis | Select-Object ScriptName, Line, Message)) }
          break
        } catch {
          Write-Warning "Invoke-ScriptAnalyzer failed on $($file.FullName). Error:"
          $results.Errors += [PSCustomObject]@{
            File      = $File.FullName
            Exception = $_.Exception | Format-List * -Force
          }
          Write-Warning "Retrying in 1 seconds."
          Start-Sleep -Seconds 1
        }
      }
      if ($i -eq $maxRetries) { Write-Warning "Invoke-ScriptAnalyzer failed $maxRetries times. Moving on." }
      if ($errorCount -gt 0) { Write-Warning "Failed to match formatting requirements" }
    }
    return $results
  }
  static [string] GetInstallPath([string]$Name, [string]$ReqVersion) {
    $p = [IO.DirectoryInfo][IO.Path]::Combine(
      $(if (!(Get-Variable -Name IsWindows -ErrorAction Ignore) -or $(Get-Variable IsWindows -ValueOnly)) {
          $_versionTable = Get-Variable PSVersionTable -ValueOnly
          $module_folder = if ($_versionTable.ContainsKey('PSEdition') -and $_versionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
          Join-Path -Path $([System.Environment]::GetFolderPath('MyDocuments')) -ChildPath $module_folder
        } else {
          Split-Path -Path ([Platform]::SelectProductNameForDirectory('USER_MODULES')) -Parent
        }
      ), 'Modules'
    )
    if (![string]::IsNullOrWhiteSpace($ReqVersion)) {
      return [IO.Path]::Combine($p.FullName, $Name, $ReqVersion)
    } else {
      return [IO.Path]::Combine($p.FullName, $Name)
    }
  }
  static [void] UpdateModule([string]$moduleName, [string]$Version) {
    [int]$ret = 0;
    try {
      if ($Version -eq 'latest') {
        Update-Module -Name $moduleName
      } else {
        Update-Module -Name $moduleName -RequiredVersion $Version
      }
    } catch {
      if ($ret -lt 1 -and $_.ErrorRecord.Exception.Message -eq "Module '$moduleName' was not installed by using Install-Module, so it cannot be updated.") {
        Get-Module $moduleName | Remove-Module -Force -ErrorAction Ignore; $ret++
        # TODO: fIX THIS mess by using: Invoke-RetriableCommand function
        [PsCraft]::UpdateModule($moduleName, $Version)
      }
    }
  }
  static [void] InstallModule([string]$moduleName, [string]$Version) {
    # There are issues with pester 5.4.1 syntax, so I'll keep using -SkipPublisherCheck.
    # https://stackoverflow.com/questions/51508982/pester-sample-script-gets-be-is-not-a-valid-should-operator-on-windows-10-wo
    $IsPester = $moduleName -eq 'Pester'
    if ($IsPester) { [void][PsCraft]::RemoveOld($moduleName) }
    if ($Version -eq 'latest') {
      Install-Module -Name $moduleName -SkipPublisherCheck:$IsPester
    } else {
      Install-Module -Name $moduleName -RequiredVersion $Version -SkipPublisherCheck:$IsPester
    }
  }
  static [bool] RemoveOld([string]$Name) {
    $m = Get-Module $Name -ListAvailable -All -Verbose:$false; [bool[]]$success = @()
    if ($m.count -gt 1) {
      $old = $m | Select-Object ModuleBase, Version | Sort-Object -Unique version -Descending | Select-Object -Skip 1 -ExpandProperty ModuleBase
      $success += $old.ForEach({
          try { Remove-Module $_ -Force -Verbose:$false -ErrorAction Ignore; Remove-Item $_ -Recurse -Force -ea Ignore } catch { $null }
          [IO.Directory]::Exists("$_")
        }
      )
    }; $IsSuccess = !$success.Contains($false)
    return $IsSuccess
  }
  static [bool] IsGitRepo([string]$path) {
    $git_command = 'git rev-parse --is-inside-work-tree'
    if ([string]::IsNullOrWhiteSpace($path)) {
      return [bool]([ScriptBlock]::Create("$git_command 2>`$null").Invoke())
    }
    return [bool]([ScriptBlock]::Create("pushd $path; $git_command 2>`$null; popd").Invoke())
  }
  static [PsCraft] From([string]$RootPath, [ref]$o) {
    $b = [PsCraft]::new();
    [Net.ServicePointManager]::SecurityProtocol = [PsCraft]::GetSecurityProtocol();
    [Environment]::SetEnvironmentVariable('IsAC', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('IsCI', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('TF_BUILD'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('RUN_ID', $(if ([bool][int]$env:IsAC -or $env:CI -eq "true") { [Environment]::GetEnvironmentVariable('GITHUB_RUN_ID') }else { [Guid]::NewGuid().Guid.substring(0, 21).replace('-', [string]::Join('', (0..9 | Get-Random -Count 1))) + '_' }), [System.EnvironmentVariableTarget]::Process);
    [PsCraft]::Useverbose = (Get-Variable VerbosePreference -ValueOnly -Scope global) -eq "continue"
    $_RootPath = [PsModuleBase]::GetunresolvedPath($RootPath);
    if ([IO.Directory]::Exists($_RootPath)) { $b.RootPath = $_RootPath }else { throw [DirectoryNotFoundException]::new("RootPath $RootPath Not Found") }
    $b.ModuleName = [Path]::GetDirectoryName($_RootPath);
    # $currentContext = [EngineIntrinsics](Get-Variable ExecutionContext -ValueOnly);
    # $b.SessionState = $currentContext.SessionState; $b.Host = $currentContext.Host
    $b.BuildOutputPath = [Path]::Combine($_RootPath, 'BuildOutput');
    $b.TestsPath = [Path]::Combine($b.RootPath, 'Tests');
    $b.dataFile = [FileInfo]::new([Path]::Combine($b.RootPath, 'en-US', "$($b.RootPath.BaseName).strings.psd1"))
    $b.buildFile = New-Item $([Path]::GetTempFileName().Replace('.tmp', '.ps1'));
    if (!$b.dataFile.Exists) { throw [FileNotFoundException]::new('Unable to find the LocalizedData file.', "$($b.dataFile.BaseName).strings.psd1") }
    [PsCraft]::LocalizedData = Read-ModuleData -File $b.dataFile
    if ($null -ne $o) {
      $o.value.GetType().GetProperties().ForEach({
          $v = $b.$($_.Name)
          if ($null -ne $v) {
            $o.value.$($_.Name) = $v
          }
        }
      )
      return $o.Value
    }; return $b
  }
  static [ParseResult] ParseCode($Code) {
    # Parses the given code and returns an object with the AST, Tokens and ParseErrors
    Write-Debug "    ENTER: ConvertToAst $Code"
    $ParseErrors = $null
    $Tokens = $null
    if ($Code | Test-Path -ErrorAction SilentlyContinue) {
      Write-Debug "      Parse Code as Path"
      $AST = [System.Management.Automation.Language.Parser]::ParseFile(($Code | Convert-Path), [ref]$Tokens, [ref]$ParseErrors)
    } elseif ($Code -is [System.Management.Automation.FunctionInfo]) {
      Write-Debug "      Parse Code as Function"
      $String = "function $($Code.Name) {`n$($Code.Definition)`n}"
      $AST = [System.Management.Automation.Language.Parser]::ParseInput($String, [ref]$Tokens, [ref]$ParseErrors)
    } else {
      Write-Debug "      Parse Code as String"
      $AST = [System.Management.Automation.Language.Parser]::ParseInput([String]$Code, [ref]$Tokens, [ref]$ParseErrors)
    }
    return [ParseResult]::new($ParseErrors, $Tokens, $AST)
  }
  static [HashSet[String]] GetCommandAlias([System.Management.Automation.Language.Ast]$Ast) {
    $Visitor = [AliasVisitor]::new(); $Ast.Visit($Visitor)
    return $Visitor.Aliases
  }
}


# .SYNOPSIS
#  BuildOrchestrator — core build logic extracted from Build-Module.ps1.
#  Inherits PsCraft for module-discovery utilities.
class BuildOrchestrator : PsCraft {
  [string[]]  $TaskList
  [string]    $Path
  [string[]]  $RequiredModules
  [PSCmdlet]  $Cmdlet
  static [scriptblock] $PSakeScriptBlock = $null

  BuildOrchestrator([string]$path, [string[]]$tasks, [string[]]$requiredModules, [PSCmdlet]$cmdlet) {
    $this.Path = $path
    $this.TaskList = $tasks
    $this.RequiredModules = $requiredModules
    $this.Cmdlet = $cmdlet
  }

  # ── Banner ──────────────────────────────────────────────────────────────────
  static [void] ShowBanner() {
    try {
      $fig = [FigletText]::new([FigletFont]'DEFAULT_3D', 'PsCraft')
      [AnsiConsole]::Console.Write($fig)
    } catch {
      Write-Host '=== PsCraft ===' -ForegroundColor Cyan
    }
  }

  # ── Package feed bootstrap ──────────────────────────────────────────────────
  [void] PreparePackageFeeds() {
    $PackageProviders = Get-PackageProvider -ListAvailable -ea Ignore -Verbose:$false
    @('NuGet', 'PowerShellGet') | ForEach-Object {
      if (!$PackageProviders.Name.Contains($_)) { Install-PackageProvider -Name $_ -Force }
      Get-PackageProvider -Name $_ -ForceBootstrap -Verbose:$false
    }
    if ($null -eq (Get-PSRepository -Name PSGallery -ea Ignore -Verbose:$false)) {
      Unregister-PSRepository -Name PSGallery -Verbose:$false -ea Ignore
      Register-PSRepository -Default -InstallationPolicy Trusted
    }
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -Verbose:$false
    }
  }

  # ── Dependency resolution ───────────────────────────────────────────────────
  [void] ResolveBuildRequirements() {
    $psd1 = [Path]::Combine($this.Path, "$([IO.DirectoryInfo]::new($this.Path).BaseName).psd1")
    if ([IO.File]::Exists($psd1)) {
      $data = [PsObject]([scriptblock]::Create("$([IO.File]::ReadAllText($psd1))").Invoke() | Select-Object *)
      $this.RequiredModules = ($data.RequiredModules + $this.RequiredModules) | Select-Object -Unique
    }
    $IsConnected = $( try {
        [Net.NetworkInformation.Ping]::new().Send('www.powershellgallery.com').Status -eq [Net.NetworkInformation.IPStatus]::Success
      } catch { $false } )
    $L = (($this.RequiredModules | Select-Object @{l = 'L'; e = { $_.Length } }).L | Sort-Object -Descending)[0]
    try {
      $status = [Status]::new([AnsiConsole]::Console.GetWriter())
      $status.RefreshRateMs = 80
      $mods = $this.RequiredModules
      $conn = $IsConnected
      $status.Start('[yellow]Resolving build dependencies...[/]', [Action[StatusContext]] {
          param($ctx)
          foreach ($name in $mods) {
            $ctx.Update("Checking $name ...")
            if ($conn) {
              Install-Module -Name $name -Verbose:$false -ea Stop
            } elseif (!((Get-Module -Name $name -ListAvailable -Verbose:$false))) {
              throw [System.Management.Automation.ItemNotFoundException]::new("Module $name is not installed.")
            }
          }
        }
      )
    } catch {
      # Status not available — fall back
      foreach ($name in $this.RequiredModules) {
        try {
          if ($IsConnected) { Install-Module -Name $name -Verbose:$false -ea Stop }
          [BuildLog]::Write(" [+] Module $name$(' ' * ($L - $name.Length)) ready")
        } catch { $this.Cmdlet.ThrowTerminatingError($_) }
      }
    }
    $psds = (Get-Module -Name $this.RequiredModules -ListAvailable -Verbose:$false).Path | Sort-Object -Unique { Split-Path $_ -Leaf }
    $psds | Import-Module -Verbose:$false -ea Stop
  }

  # ── Dispatch ────────────────────────────────────────────────────────────────
  [int] Run([string[]]$tasks) {
    [Environment]::SetEnvironmentVariable('IsAC', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('IsCI', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('TF_BUILD'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('RUN_ID', $(if ([bool][int]$env:IsAC -or $env:CI -eq 'true') { [Environment]::GetEnvironmentVariable('GITHUB_RUN_ID') } else { [Guid]::NewGuid().Guid.Substring(0, 21).Replace('-', [string]::Join('', (0..9 | Get-Random -Count 1))) + '_' }), [System.EnvironmentVariableTarget]::Process)
    Set-BuildVariables $this.Path $env:RUN_ID
    [BuildLog]::WriteHeading("Invoking tasks: [ $($tasks -join ', ') ]")
    $script:Psake_BuildFile = New-Item $([IO.Path]::GetTempFileName().Replace('.tmp', '.ps1'))
    $sbText = [BuildOrchestrator]::PSakeScriptBlock.ToString().Replace('<build_requirements>', [string]('@("' + ($this.RequiredModules -join '", "') + '")'))
    Set-Content -Path $script:Psake_BuildFile -Value $sbText | Out-Null
    try {
      $psakeParams = @{ nologo = $true; buildFile = $script:Psake_BuildFile.FullName; taskList = $tasks }
      Invoke-Psake @psakeParams
    } catch {
      $global:psake.error_message = $_
      $this.Cmdlet.ThrowTerminatingError($_)
    } finally {
      Remove-Item $script:Psake_BuildFile -Force -ea Ignore -Verbose:$false | Out-Null
    }
    return [int](!$global:psake.build_success)
  }

  # ── Post-build: local repo publish + env cleanup ────────────────────────────
  [void] Finalize([bool]$success) {
    [BuildLog]::WriteEnvironmentSummary("Build $($success ? 'complete' : 'Failed')")
    $LocalPSRepo = if (!(Get-Variable -Name IsWindows -ea Ignore) -or $(Get-Variable IsWindows -ValueOnly)) {
      [IO.Path]::Combine([Environment]::GetEnvironmentVariable('UserProfile'), 'LocalPSRepo')
    } else { [IO.Path]::Combine([Environment]::GetEnvironmentVariable('HOME'), 'LocalPSRepo') }

    if ($success) {
      [BuildLog]::WriteHeading('Create a Local repository')
      if (!(Test-Path -Path $LocalPSRepo -PathType Container -ea Ignore)) { New-Item -Path $LocalPSRepo -ItemType Directory | Out-Null }
      Register-PSRepository LocalPSRepo -SourceLocation $LocalPSRepo -PublishLocation $LocalPSRepo -InstallationPolicy Trusted -Verbose:$false -ea Ignore
      Register-PackageSource -Name LocalPsRepo -Location $LocalPSRepo -Trusted -ProviderName Bootstrap -ea Ignore
      if ($null -ne (Get-PSRepository LocalPSRepo -Verbose:$false -ea Ignore)) {
        $ModuleName = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
        $BuildNumber = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildNumber')
        $ModulePath = [IO.Path]::Combine($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput')), $ModuleName, $BuildNumber)
        $ModulePackage = [IO.Path]::Combine($LocalPSRepo, "${ModuleName}.${BuildNumber}.nupkg")
        if ([IO.File]::Exists($ModulePackage)) { Remove-Item -Path $ModulePackage -Force -ea SilentlyContinue }
        [BuildLog]::WriteHeading('Publish to Local PsRepository')
        $RequiredMods = Read-ModuleData -File ([IO.Path]::Combine($ModulePath, "$ModuleName.psd1")) -Property RequiredModules -Verbose:$false
        foreach ($m in $RequiredMods) {
          $mdPath = (Get-Module $m -ListAvailable -Verbose:$false)[0].Path | Split-Path
          Publish-Module -Path $mdPath -Repository LocalPSRepo -Verbose:$false -ea Ignore
        }
        Publish-Module -Path $ModulePath -Repository LocalPSRepo -Verbose:$false
        Install-Module $ModuleName -Repository LocalPSRepo -Force -Verbose:$false
      } else {
        $this.Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new([Exception]::new('Failed to create LocalPsRepo'), 'LocalPsRepo_NOT_FOUND', 'ObjectNotFound', $LocalPSRepo))
      }
    }

    # Env cleanup
    if (![bool][int]$env:IsAC) {
      [BuildLog]::WriteHeading("CleanUp: Remove env variables")
      if (![string]::IsNullOrWhiteSpace($env:RUN_ID)) {
        $OldEnvNames = [Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like "$env:RUN_ID*" }
        foreach ($Name in $OldEnvNames) {
          [BuildLog]::Write("Remove env variable $Name")
          [Environment]::SetEnvironmentVariable($Name, $null)
        }
      }
      $ModuleName = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
      $BuildNumber = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildNumber')
      if ($ModuleName) { Uninstall-Module $ModuleName -MinimumVersion $BuildNumber -Force -ea Ignore }
      if ([IO.Directory]::Exists($LocalPSRepo)) {
        Invoke-Command -ScriptBlock ([scriptblock]::Create("Unregister-PSRepository -Name 'LocalPSRepo' -Verbose:`$false -ea Ignore"))
        Remove-Item $LocalPSRepo -Verbose:$false -Force -Recurse -ea Ignore
      }
      [Environment]::SetEnvironmentVariable('RUN_ID', $null)
    }
  }

  # ── Help display ─────────────────────────────────────────────────────────────
  [void] ShowHelp([string]$buildFile) {
    [BuildLog]::WriteHeading('Getting help')
    try {
      $tasks = Get-PSakeScriptTasks -BuildFile $buildFile | Sort-Object -Property Name
      $table = [Table]::new()
      [void]$table.AddColumn([TableColumn]::new('Name'))
      [void]$table.AddColumn([TableColumn]::new('Description'))
      [void]$table.AddColumn([TableColumn]::new('DependsOn'))
      foreach ($t in $tasks) {
        [void]$table.AddRow(@($t.Name, "$($t.Description)", "$($t.DependsOn -join ', ')"))
      }
      [AnsiConsole]::Console.Write($table)
    } catch {
      Get-PSakeScriptTasks -BuildFile $buildFile | Sort-Object Name | Format-Table Name, Description, DependsOn -AutoSize
    }
  }
}

$global:OutputEncoding = [console]::InputEncoding = [console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# Types that will be available to users when they import the module.
# Hint: To automatically update the typestoexport variable you can use:
# .\scripts\update_exporatable_types.ps1

$typestoExport = @(
  [BuildLog], [SaveOptions], [PSEdition], [ModuleItemAttribute], [ParseResult], [AliasVisitor], [PsModuleData], [PsModule], [PsCraft], [BuildOrchestrator], [PsCraft]
)
$TypeAcceleratorsClass = [PsObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
# Add type accelerators for every exportable type.
foreach ($Type in $typestoExport) {
  try {
    [void]$TypeAcceleratorsClass::Add($Type.FullName, $Type)
  } catch {
    # Ignore if already exists
    $null
  }
}
# Remove type accelerators when the module is removed.
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
  foreach ($Type in $typestoExport) {
    $TypeAcceleratorsClass::Remove($Type.FullName)
  }
}.GetNewClosure();

$scripts = @();
$Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += Get-ChildItem "$PSScriptRoot/Private" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += $Public

foreach ($file in $scripts) {
  try {
    if ([string]::IsNullOrWhiteSpace($file.fullname)) { continue }
    . "$($file.fullname)"
  } catch {
    Write-Warning "Failed to import function $($file.BaseName): $_"
    $host.UI.WriteErrorLine($_)
  }
}

$Param = @{
  Function = $Public.BaseName
  Cmdlet   = '*'
  Alias    = '*'
  Verbose  = $false
}
Export-ModuleMember @Param
