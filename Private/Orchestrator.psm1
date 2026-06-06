#!/usr/bin/env pwsh
using namespace System.IO
using namespace System.Collections.Generic
using namespace System.Management.Automation
using namespace System.Management.Automation.Language

using module .\Enums.psm1
using module .\ModuleData.psm1
using module .\BuildLog.psm1

class AliasVisitor : System.Management.Automation.Language.AstVisitor {
  [string]$Parameter = $null
  [string]$Command = $null
  [string]$Name = $null
  [string]$Value = $null
  [string]$Scope = $null
  [System.Collections.Generic.HashSet[string]]$Aliases = @()

  # Parameter Names
  [AstVisitAction] VisitCommandParameter([CommandParameterAst]$ast) {
    $this.Parameter = $ast.ParameterName
    return [AstVisitAction]::Continue
  }

  # Parameter Values
  [AstVisitAction] VisitStringConstantExpression([StringConstantExpressionAst]$ast) {
    # The FIRST command element is always the command name
    if (!$this.Command) {
      $this.Command = $ast.Value
      return [AstVisitAction]::Continue
    } else {
      # Nobody should use minimal parameters like -N for -Name ...
      # But if they do, our parser works anyway!
      switch -Wildcard ($this.Parameter) {
        "S*" {
          $this.Scope = $ast.Value
        }
        "N*" {
          $this.Name = $ast.Value
        }
        "Va*" {
          $this.Value = $ast.Value
        }
        "F*" {
          if ($ast.Value) {
            # Force parameter was passed as named parameter with a positional parameter after it which is alias name
            $this.Name = $ast.Value
          }
        }
        default {
          if (!$this.Parameter) {
            # For bare arguments, the order is Name, Value:
            if (!$this.Name) {
              $this.Name = $ast.Value
            } else {
              $this.Value = $ast.Value
            }
          }
        }
      }
      $this.Parameter = $null
      # If we have enough information, stop the visit
      # For -Scope global or Remove-Alias, we don't want to export these
      if ($this.Name -and $this.Command -eq "Remove-Alias") {
        $this.Command = "Remove-Alias"
        return [AstVisitAction]::StopVisit
      } elseif ($this.Name -and $this.Scope -eq "Global") {
        return [AstVisitAction]::StopVisit
      }
      return [AstVisitAction]::Continue
    }
  }

  # The [Alias(...)] attribute on functions matters, but we can't export aliases that are defined inside a function
  [AstVisitAction] VisitFunctionDefinition([FunctionDefinitionAst]$ast) {
    @($ast.Body.ParamBlock.Attributes.Where{ $_.TypeName.Name -eq "Alias" }.PositionalArguments.Value).ForEach{
      if ($_) {
        $this.Aliases.Add($_)
      }
    }
    return [AstVisitAction]::SkipChildren
  }

  # Top-level commands matter, but only if they're alias commands
  [AstVisitAction] VisitCommand([CommandAst]$ast) {
    if ($ast.CommandElements[0].Value -imatch "(New|Set|Remove)-Alias") {
      $ast.Visit($this.ClearParameters())
      $Params = $this.GetParameters()
      # We COULD just remove it (even if we didn't add it) ...
      if ($Params.Command -ieq "Remove-Alias") {
        # But Write-Verbose for logging purposes
        if ($this.Aliases.Contains($Params.Name)) {
          Write-Verbose -Message "Alias '$($Params.Name)' is removed by line $($ast.Extent.StartLineNumber): $($ast.Extent.Text)"
          $this.Aliases.Remove($Params.Name)
        }
        # We don't need to export global aliases, because they broke out already
      } elseif ($Params.Name -and $Params.Scope -ine 'Global') {
        $this.Aliases.Add($this.Parameters.Name)
      }
    }
    return [AstVisitAction]::SkipChildren
  }
  [PSCustomObject] GetParameters() {
    return [PSCustomObject]@{
      PSTypeName = "PsCraft.AliasVisitor.AliasParameters"
      Name       = $this.Name
      Command    = $this.Command
      Parameter  = $this.Parameter
      Value      = $this.Value
      Scope      = $this.Scope
    }
  }
  [AliasVisitor] ClearParameters() {
    $this.Command = $null
    $this.Parameter = $null
    $this.Name = $null
    $this.Value = $null
    $this.Scope = $null
    return $this
  }
}

class ParseResult {
  [Token[]]$Tokens
  [ScriptBlockAst]$AST
  [ParseError[]]$ParseErrors

  ParseResult([ParseError[]]$Errors, [Token[]]$Tokens, [ScriptBlockAst]$AST) {
    $this.Init($Errors, $Tokens, $AST)
  }

  hidden [void] Init([ParseError[]]$Errors, [Token[]]$Tokens, [ScriptBlockAst]$AST) {
    $this.ParseErrors = $Errors
    $this.Tokens = $Tokens
    $this.AST = $AST
  }
}

# Build context encapsulates all state needed during a build operation
# This replaces scattered environment variables with a cohesive context object
class BuildContext {
  # Project information
  [string]$ProjectName
  [string]$ProjectPath
  [version]$BuildNumber
  [string]$BuildSystem          # 'GitHub', 'Azure', 'Local'

  # Build environment
  [bool]$IsCI                   # Running in CI/CD environment
  [bool]$IsGitHubActions        # Running in GitHub Actions specifically
  [string]$RunId                # Unique identifier for this build run

  # Build paths
  [string]$BuildOutputPath
  [string]$BuildScriptPath      # Path to build script directory
  [string]$PSModulePath         # Output module path
  [string]$PSModuleManifest     # Manifest file path

  # SCM information
  [string]$CommitMessage
  [string]$BranchName
  [string]$CommitId

  # Release information
  [string]$ReleaseNotes

  hidden [datetime] $_startTime

  static [hashtable[]] $MemberDefinitions = @(
    @{
      MemberType = 'ScriptProperty'
      MemberName = 'TotalDuration'
      Value      = { return [datetime]::Now - $this._startTime }
    }
  )

  static BuildContext() {
    foreach ($d in [BuildContext]::MemberDefinitions) {
      # Update-TypeData -TypeName ([BuildContext].Name) @d -ErrorAction Ignore
    }
  }

  # Constructor with required parameters
  BuildContext([string]$ProjectName, [string]$ProjectPath, [version]$BuildNumber) {
    $this.Init($ProjectName, $ProjectPath, $BuildNumber)
  }

  hidden [void] Init([string]$ProjectName, [string]$ProjectPath, [version]$BuildNumber) {
    $this._startTime = [datetime]::Now
    $this.ProjectName = $ProjectName
    $this.ProjectPath = $ProjectPath
    $this.BuildNumber = $BuildNumber
    $this.RunId = [Guid]::NewGuid().Guid.Substring(0, 21).Replace('-', '')
    $this.IsCI = [bool]([Environment]::GetEnvironmentVariable('CI') -eq 'true')
    $this.IsGitHubActions = ![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))
    $this.BuildSystem = $this.DetectBuildSystem()
    $this.BuildOutputPath = [IO.Path]::Combine($ProjectPath, 'BuildOutput')
    $this.BuildScriptPath = $ProjectPath
    $this.PSModulePath = [IO.Path]::Combine($this.BuildOutputPath, $ProjectName)
    $this.PSModuleManifest = [IO.Path]::Combine($this.PSModulePath, "$ProjectName.psd1")
    $this.CommitMessage = $this.GetCommitMessage()
    $this.BranchName = $this.GetBranchName()
    $this.CommitId = $this.GetCommitId()
    $this.ReleaseNotes = ''
  }

  [string] ToString() {
    return "$($this.ProjectName) v$($this.BuildNumber) [$($this.BuildSystem)]"
  }

  # Detect the build system we're running in
  [string] DetectBuildSystem() {
    if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))) {
      return 'GitHub'
    }
    if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('SYSTEM_TEAMFOUNDATIONCOLLECTIONURI'))) {
      return 'Azure'
    }
    return 'Local'
  }

  # Get commit message from environment or git
  [string] GetCommitMessage() {
    $msg = [Environment]::GetEnvironmentVariable('GITHUB_EVENT_COMMIT_MESSAGE')
    if ([string]::IsNullOrWhiteSpace($msg)) {
      try { $msg = & git log -1 --pretty=%B } catch { $msg = '' }
    }
    return $msg
  }

  # Get branch name from environment or git
  [string] GetBranchName() {
    $branch = [Environment]::GetEnvironmentVariable('GITHUB_REF')
    if ([string]::IsNullOrWhiteSpace($branch)) {
      try { $branch = & git rev-parse --abbrev-ref HEAD } catch { $branch = 'unknown' }
    }
    return $branch -replace 'refs/heads/', ''
  }

  # Get commit ID from environment or git
  [string] GetCommitId() {
    $id = [Environment]::GetEnvironmentVariable('GITHUB_SHA')
    if ([string]::IsNullOrWhiteSpace($id)) {
      try { $id = & git rev-parse --verify HEAD } catch { $id = '' }
    }
    return $id
  }

  # Get output directory for a specific version
  [string] GetVersionedOutputPath() {
    return [IO.Path]::Combine($this.PSModulePath, $this.BuildNumber.ToString())
  }

  # Export context to environment (for backwards compatibility with PSake scripts)
  [void] ExportToEnvironment() {
    $prefix = $this.RunId
    [Environment]::SetEnvironmentVariable("${prefix}ProjectName", $this.ProjectName, 'Process')
    [Environment]::SetEnvironmentVariable("${prefix}BuildNumber", $this.BuildNumber.ToString(), 'Process')
    [Environment]::SetEnvironmentVariable("${prefix}ProjectPath", $this.ProjectPath, 'Process')
    [Environment]::SetEnvironmentVariable("${prefix}BuildOutput", $this.BuildOutputPath, 'Process')
    [Environment]::SetEnvironmentVariable("${prefix}BuildSystem", $this.BuildSystem, 'Process')
    [Environment]::SetEnvironmentVariable("${prefix}CommitMessage", $this.CommitMessage, 'Process')
    [Environment]::SetEnvironmentVariable("${prefix}BranchName", $this.BranchName, 'Process')
    [Environment]::SetEnvironmentVariable("${prefix}ReleaseNotes", $this.ReleaseNotes, 'Process')
    [Environment]::SetEnvironmentVariable("${prefix}PSModuleManifest", $this.PSModuleManifest, 'Process')
    [Environment]::SetEnvironmentVariable("${prefix}PSModulePath", $this.PSModulePath, 'Process')
    [Environment]::SetEnvironmentVariable("${prefix}BuildScriptPath", $this.BuildScriptPath, 'Process')
  }

  # Clear environment variables when build is complete
  [void] ClearEnvironment() {
    $prefix = $this.RunId
    @(
      'ProjectName', 'BuildNumber', 'ProjectPath', 'BuildOutput', 'BuildSystem',
      'CommitMessage', 'BranchName', 'ReleaseNotes', 'PSModuleManifest',
      'PSModulePath', 'BuildScriptPath'
    ) | ForEach-Object {
      [Environment]::SetEnvironmentVariable("${prefix}$_", $null, 'Process')
    }
  }
}

class PsModule : IDisposable {
  [ValidateNotNullOrEmpty()] [String]$Name;
  [ValidateNotNullOrEmpty()] [IO.DirectoryInfo]$Path;
  [PsModuleData] $data;
  [List[ModuleFile]]$Files;
  [List[ModuleFolder]]$Folders;
  static [hashtable] $Config
  PsModule() {
    $this.Init($null, $null, [System.Management.Automation.ModuleType]::Script)
  }
  PsModule([string]$Name) {
    $this.Init($Name, $null, [System.Management.Automation.ModuleType]::Script)
  }
  PsModule([string]$Name, [System.Management.Automation.ModuleType]$Type) {
    $this.Init($Name, $null, $Type)
  }
  PsModule([string]$Name, [IO.DirectoryInfo]$Path) {
    $this.Init($Name, $Path, [System.Management.Automation.ModuleType]::Script)
  }
  PsModule([string]$Name, [IO.DirectoryInfo]$Path, [System.Management.Automation.ModuleType]$Type) {
    $this.Init($Name, $Path, $Type)
  }
  static [PsModule] Create([string]$Name) { return [PsModule]::new($Name, [System.Management.Automation.ModuleType]::Script) }
  static [PsModule] Create([string]$Name, [System.Management.Automation.ModuleType]$Type) { return [PsModule]::new($Name, $Type) }
  static [PsModule] Create([string]$Name, [string]$Path) { return [PsModule]::new($Name, [IO.DirectoryInfo]::new($Path), [System.Management.Automation.ModuleType]::Script) }

  static [PsModule] Create([string]$Name, [string]$Path, [System.Management.Automation.ModuleType]$Type) {
    $b = [PsModuleBase]::GetunResolvedPath($Path); $p = [IO.Path]::Combine($b, $Name);
    $d = [IO.DirectoryInfo]::new($p); if (![IO.Directory]::Exists($d)) {
      return [PsModule]::new($d.BaseName, $d.Parent, $Type)
    }
    [BuildLog]::Write("[WIP] Load Module from $p")
    return [PsModule]::Load($d)
  }

  hidden [void] Init([string]$Name, [IO.DirectoryInfo]$Path, [System.Management.Automation.ModuleType]$Type) {
    if ($null -ne [PsModule]::Config) {
      # Config includes:
      # - Build steps
      # - Params ...
    }
    $resolvedPath = $Path
    if ($null -eq $resolvedPath -or [string]::IsNullOrWhiteSpace($resolvedPath.FullName)) {
      $resolvedPath = [IO.DirectoryInfo]::new((Get-Location).Path)
    }
    $this.Name = [string]::IsNullOrWhiteSpace($Name) ? [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetRandomFileName()) : $Name
    $mName = $this.Name
    $moduleRoot = if ($null -ne $resolvedPath -and -not [string]::IsNullOrWhiteSpace($resolvedPath.FullName)) { $resolvedPath.FullName } else { (Get-Location).Path }
    $mroot = [System.IO.Path]::Combine($moduleRoot, $mName)
    [void][PsModuleBase]::validatePath($mroot); $this.Path = $mroot
    $this.Files = New-Object System.Collections.Generic.List[ModuleFile]
    $this.Folders = New-Object System.Collections.Generic.List[ModuleFolder]
    try {
      $this.Data = [PsModuleData]::new($this.Name, $Type, $this.Path)
      $this.Data.Path = $this.Path
      $schema = $this.Data.defaults.GetModuleSchema($mName, $Type)

      [PsModuleData]::GetModuleFiles($mName, $mroot, $schema) | ForEach-Object { $this.Files.Add($_) }
      [PsModuleData]::GetModuleSubFolders($mName, $mroot, $schema) | ForEach-Object { $this.Folders.Add($_) }
      if ($null -ne $this.Data.defaults) {
        $this.Data.defaults.GetDefaults().GetEnumerator().ForEach({
            $k = $_.Key; $v = $_.Value
            # Replace <ModuleName> and {mName} tokens with the actual module name
            if ($v -is [scriptblock]) {
              $str = $v.ToString().Replace('<ModuleName>', $mName).Replace('{mName}', $mName)
              $this.Data[$k] = [scriptblock]::Create($str)
            } elseif ($v -is [string]) {
              $this.Data[$k] = $v.Replace('<ModuleName>', $mName).Replace('{mName}', $mName)
            } else {
              $this.Data[$k] = $v
            }
          }
        )
      }
    } catch {
      [BuildLog]::WriteWarning("$($_ | Format-List * -Force | Out-String)")
    }
    # Lets Make sure Set required manifest fields that New-ModuleManifest always needs
    $this.Data['Path'] = [System.IO.Path]::Combine($mroot, "$mName.psd1")
    if ($Type -eq [System.Management.Automation.ModuleType]::Script) {
      $this.Data['RootModule'] = "$mName.psm1"
    } elseif ($Type -eq [System.Management.Automation.ModuleType]::Binary) {
      $this.Data['RootModule'] = "$mName.dll"
    } elseif ($Type -eq [System.Management.Automation.ModuleType]::Cim) {
      $this.Data['RootModule'] = "Cim/$mName.cdxml"
    } else {
      $this.Data['RootModule'] = ''
    }
    $this.Data['Author'] = PsModuleBase\Get-AuthorName
    $this.Data['ModuleVersion'] = '0.1.0'
    $this.Data['Description'] = "A collection of script files by $(PsModuleBase\Get-AuthorName)"
  }
  [void] Save() {
    $this.Save([SaveOptions]::None)
  }
  [void] Save([SaveOptions]$Options) {
    if ([string]::IsNullOrWhiteSpace($this.Name)) {
      throw [System.ArgumentNullException]::New('$this.Name', "Make sure module Name is not empty")
    }
    $this.WritetoDisk($Options)
  }
  [void] Set([string]$Key, $Value) {
    $this.Data[$Key] = $Value
  }
  [void] FormatCode() {
    $type = [type]"PsCraft"
    $type::FormatCode($this)
  }
  [void] WritetoDisk([SaveOptions]$Options) {
    $Force = $Options -eq [SaveOptions]::None
    $debug = $($Script:DebugPreference) -eq "Continue"
    [BuildLog]::WriteStep("Create Module Directories")
    $this.Folders | ForEach-Object {
      $nF = @(); $p = $_.value; while (!$p.Exists) { $nF += $p; $p = $p.Parent }
      [Array]::Reverse($nF);
      foreach ($d in $nF) {
        New-Item -Path $d.FullName -ItemType Directory -Force:$Force | Out-Null
        if ($debug) { Write-Debug "Created Directory '$($d.FullName)'" }
      }
    }
    [BuildLog]::WriteStatus("Directory structure created", 'success')

    [BuildLog]::WriteStep("Create Module Files")
    $this.GetFiles().ForEach({
        $content = if ($null -ne $_.Content) { $_.Content.ToString() } else { '' }
        [IO.File]::WriteAllText($_.Path.FullName, $content, [System.Text.Encoding]::UTF8)
        if ($debug) { Write-Debug "Created $($_.Name)" }
      })
    # Build manifest params from Files that have ManifestKey attribute
    $PM = @{}
    $this.Files.Where({ $_.Attributes -contains 'ManifestKey' }).ForEach({
        $v = $this.Data[$_.Name]
        if ($null -ne $v) { $PM[$_.Name] = $v }
      }
    )
    # Always ensure Path is set for New-ModuleManifest
    if (!$PM.ContainsKey('Path')) {
      $PM['Path'] = [IO.Path]::Combine($this.Path.FullName, "$($this.Name).psd1")
    }
    New-ModuleManifest @PM | Out-Null
    [BuildLog]::WriteStatus("Module files created", 'success')
  }
  static [PsModule] Load([IO.DirectoryInfo]$Path) {
    [void][PsModuleBase]::validatePath($Path.FullName)
    $psd1Files = Get-ChildItem -Path $Path.FullName -Filter "*.psd1" -ErrorAction Ignore
    if (!$psd1Files) {
      throw [System.IO.FileNotFoundException]::new("No .psd1 manifest file found in directory $($Path.FullName)")
    }
    $psd1 = $psd1Files[0]
    $mName = $psd1.BaseName

    # Import manifest data
    $manifestData = Import-PowerShellDataFile -Path $psd1.FullName -ErrorAction Stop

    # Determine module type
    $type = [System.Management.Automation.ModuleType]::Manifest
    $rootModule = $manifestData.RootModule ?? $manifestData.NestedModules

    if ($rootModule) {
      $rootModuleStr = $rootModule -join ''
      if ($rootModuleStr -like "*.dll") {
        $type = [System.Management.Automation.ModuleType]::Binary
      } elseif ($rootModuleStr -like "*.cdxml") {
        $type = [System.Management.Automation.ModuleType]::Cim
      } elseif ($rootModuleStr -like "*.psm1") {
        $type = [System.Management.Automation.ModuleType]::Script
      }
    } else {
      # Fallback checks on folders
      if (Test-Path -Path [IO.Path]::Combine($Path.FullName, "src") -PathType Container) {
        $type = [System.Management.Automation.ModuleType]::Binary
      } elseif (Test-Path -Path [IO.Path]::Combine($Path.FullName, "Cim") -PathType Container) {
        $type = [System.Management.Automation.ModuleType]::Cim
      }
    }

    # Create the PsModule object using the correct Type
    $module = New-Object PsModule
    $module.Name = $mName
    $module.Path = $Path

    $module.Files = [System.Collections.Generic.List[psobject]]::new()
    $module.Folders = [System.Collections.Generic.List[psobject]]::new()

    $defaults = [PsModuleDefaults]::new($mName, $type, $Path)
    $schema = $defaults.GetModuleSchema($mName, $type)

    $module.Data = [PsModuleData]::new($mName, $type, $Path)

    # Copy manifest keys to Data
    $manifestData.GetEnumerator().ForEach({
        $module.Data[$_.Key] = $_.Value
      }
    )

    # Re-populate Files and Folders lists
    [PsModuleData]::GetModuleFiles($mName, $Path.FullName, $schema) | ForEach-Object { $module.Files.Add($_) }
    [PsModuleData]::GetModuleSubFolders($mName, $Path.FullName, $schema) | ForEach-Object { $module.Folders.Add($_) }

    return $module
  }
  static [PsModule] Load([string]$Path) {
    return [PsModule]::Load([IO.DirectoryInfo]::new([PsModuleBase]::GetResolvedPath($Path)))
  }
  static [PsModule] Load([string]$Name, [string]$Path) {
    return [PsModule]::Load([IO.DirectoryInfo]::new([PsModuleBase]::GetResolvedPath([IO.Path]::Combine($Path, $Name))))
  }
  [PsObject[]] GetFiles() {
    # Join Files (which have path info + attributes) with Data (which has content values)
    $MF = $this.Files.Where({ $_.Attributes -contains 'FileContent' -and $_.Attributes -notcontains 'ManifestKey' }) |
      Select-Object Name, @{l = 'Path'; e = { $_.value } }, @{l = 'Content'; e = { $this.Data[$_.Name] } }
    return $MF
  }
  [bool] Test() {
    $testsDir = [IO.Path]::Combine($this.Path.FullName, "Tests")
    if (!(Test-Path $testsDir)) { return $true }
    $testFiles = Get-ChildItem -Path $testsDir -Filter "*.ps1" -File
    if (!$testFiles) { return $true }

    $testRunner = $null
    try { $testRunner = New-Object ThreadRunner } catch { [BuildLog]::WriteWarning("Failed to create ThreadRunner "); $null }
    if ($null -eq $testRunner) {
      $success = $true
      foreach ($file in $testFiles) {
        $r = Invoke-Pester -Path $file.FullName -PassThru -ErrorAction SilentlyContinue
        if ($r.FailedCount -gt 0 -or $r.Result -ne 'Passed') { $success = $false }
      }
      return $success
    }

    foreach ($testFile in $testFiles) {
      $testRunner.AddJob("Test $($testFile.Name)", {
          param($file)
          return Invoke-Pester -Path $file -PassThru -ErrorAction Stop
        }, $testFile.FullName
      )
    }

    $results = $testRunner.ExecuteAll()
    $success = $true
    foreach ($r in $results) {
      if (!$r.Success) {
        $success = $false
      } elseif ($null -ne $r.Output -and $r.Output.FailedCount -gt 0) {
        $success = $false
      }
    }
    return $success
  }
  [void] Publish() {
    $this.Publish('LocalRepo', [System.IO.Path]::GetDirectoryName($Pwd))
  }
  [void] Publish($repoName, $repoPath) {
    if (Test-Path -Type Container -Path $repoPath -ErrorAction SilentlyContinue) {
      throw ""
    } else {
      New-Item -Path $repoPath -ItemType Directory | Out-Null
    }
    $this.Save()
    # If the PSrepo is not known, create one.
    if (![bool](Get-PSRepository "$repoName" -ErrorAction SilentlyContinue).Trusted) {
      $repoParams = @{
        Name               = $repoName
        SourceLocation     = $repoPath
        PublishLocation    = $repoPath
        InstallationPolicy = 'Trusted'
      }
      Register-PSRepository @repoParams
    }
    Publish-Module -Path $this.Path.FullName -Repository $repoName
    Install-Module $this.Name -Repository $repoName
  }
  static [void] Publish ([string]$Path, [securestring]$ApiKey, [bool]$IncrementVersion ) {
    $moduleName = Split-Path $Path -Leaf
    $functions = Get-PsModuleFunctions $Path -PublicOnly
    if ($IncrementVersion) {
      $moduleFile = "$((Join-Path $path $moduleName)).psd1"
      $file = Import-PowerShellDataFile $moduleFile -Verbose:$false;
      [version]$version = ($file).ModuleVersion
      [version]$newVersion = "{ 0 }.{ 1 }.{ 2 }" -f $version.Major, $version.Minor, ($version.Build + 1)
      Update-ModuleManifest -Path "$((Join-Path $Path $moduleName)).psd1" -FunctionsToExport $functions -ModuleVersion $newVersion;
    } else {
      Update-ModuleManifest -Path "$((Join-Path $Path $moduleName)).psd1" -FunctionsToExport $functions;
    }
    Publish-Module -Path $Path -NuGetApiKey $ApiKey;
    [BuildLog]::WriteStatus("Module $moduleName Published", 'success');
  }
  [void] Dispose() {
    $this.Data = $null
    if ($null -ne $this.Files) { $this.Files.Clear() }
    if ($null -ne $this.Folders) { $this.Folders.Clear() }
  }

  [bool] Equals([object]$other) {
    if ($null -eq $other) { return $false }
    if ([object]::ReferenceEquals($this, $other)) { return $true }
    $o = $other -as [PsModule]
    if ($null -eq $o) { return $false }
    return ($this.Name -eq $o.Name) -and ($this.Path.FullName -eq $o.Path.FullName)
  }

  [int] GetHashCode() {
    $hash = 17
    if ($null -ne $this.Name) { $hash = $hash * 23 + $this.Name.GetHashCode() }
    if ($null -ne $this.Path) { $hash = $hash * 23 + $this.Path.FullName.GetHashCode() }
    return $hash
  }

  [string] ToString() {
    return "$($this.Name) @ $($this.Path.FullName)"
  }
}


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

class PsCraft : Microsoft.PowerShell.Commands.ModuleCmdletBase {
  [ValidateNotNullOrWhiteSpace()][string]$ModuleName
  [ValidateNotNullOrWhiteSpace()][string]$BuildOutputPath # $RootPath/BouldOutput/$ModuleName
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$RootPath # Module Project root
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$TestsPath
  [ValidateNotNullOrEmpty()][version]$ModuleVersion
  [ValidateNotNullOrEmpty()][System.IO.FileInfo]$dataFile # ..strings.psd1
  [ValidateNotNullOrEmpty()][System.IO.FileInfo]$buildFile
  [IO.DirectoryInfo]$LocalPSRepo
  [PsObject]$LocalizedData
  [System.Management.Automation.PSCmdlet]$CallerCmdlet
  [bool]$UseVerbose
  [BuildContext]$BuildContext
  [System.Collections.Generic.List[string]]$TaskList

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
  static [object[]] Search([string]$Name) {
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
      Analysis = [System.Collections.Generic.List[PSCustomObject]]@()
      Errors   = [System.Collections.Generic.List[PSCustomObject]]@()
    }
    if (![IO.Directory]::Exists($module.Path.FullName)) {
      [BuildLog]::WriteWarning("Module path '$($module.Path.FullName)' does not exist. Please run `$module.save() first.")
      return $results
    }
    $filesToCheck = $module.Files.Value.Where({ $_.Extension -in ('.ps1', '.psd1', '.psm1') })
    $frmtSettings = $module.Files.Where({ $_.Name -eq "ScriptAnalyzer" })[0].Value.FullName
    if ($filesToCheck.Count -eq 0) {
      [BuildLog]::WriteStatus("No files to format found in the module!", 'warning')
      return $results
    }
    if (!$frmtSettings) {
      [BuildLog]::WriteWarning("ScriptAnalyzer Settings not found in the module!")
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
          [BuildLog]::WriteWarning("Invoke-ScriptAnalyzer failed on $($file.FullName). Error:")
          $results.Errors += [PSCustomObject]@{
            File      = $File.FullName
            Exception = $_.Exception | Format-List * -Force
          }
          [BuildLog]::WriteWarning("Retrying in 1 seconds.")
          Start-Sleep -Seconds 1
        }
      }
      if ($i -eq $maxRetries) { [BuildLog]::WriteWarning("Invoke-ScriptAnalyzer failed $maxRetries times. Moving on.") }
      if ($errorCount -gt 0) { [BuildLog]::WriteWarning("Failed to match formatting requirements") }
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
          try {
            Remove-Module $_ -Force -Verbose:$false -ErrorAction Ignore; Remove-Item $_ -Recurse -Force -ea Ignore
          } catch {
            [BuildLog]::WriteWarning("Failed to remove module: $($_ | Format-List * -Force | Out-String)")
          }
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

    # Initialize the build context instead of scattering environment variables
    $projName = [IO.DirectoryInfo]::new($RootPath).BaseName
    $b.BuildContext = [BuildContext]::new($projName, $RootPath, '0.0.0')
    $b.UseVerbose = $Script:VerbosePreference -eq "Continue"

    $_RootPath = [PsModuleBase]::GetunresolvedPath($RootPath);
    if ([IO.Directory]::Exists($_RootPath)) { $b.RootPath = $_RootPath }else { throw [DirectoryNotFoundException]::new("RootPath $RootPath Not Found") }
    $b.ModuleName = [IO.DirectoryInfo]::new($_RootPath).BaseName;
    # $currentContext = [EngineIntrinsics](Get-Variable ExecutionContext -ValueOnly);
    # $b.SessionState = $currentContext.SessionState; $b.Host = $currentContext.Host
    $b.BuildOutputPath = [System.IO.Path]::Combine($_RootPath, 'BuildOutput');
    $b.TestsPath = [System.IO.Path]::Combine($b.RootPath, 'Tests');
    $b.dataFile = [System.IO.FileInfo]::new([System.IO.Path]::Combine($b.RootPath, 'en-US', "$($b.RootPath.BaseName).strings.psd1"))
    $b.buildFile = New-Item $([System.IO.Path]::GetTempFileName().Replace('.tmp', '.ps1'));
    if (!$b.dataFile.Exists) { throw [System.IO.FileNotFoundException]::new('Unable to find the LocalizedData file.', "$($b.dataFile.BaseName).strings.psd1") }
    $b.LocalizedData = Read-ModuleData -File $b.dataFile
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
  static [System.Collections.Generic.HashSet[String]] GetCommandAlias([System.Management.Automation.Language.Ast]$Ast) {
    $Visitor = [AliasVisitor]::new(); $Ast.Visit($Visitor)
    return $Visitor.Aliases
  }
}



# .SYNOPSIS
#  BuildOrchestrator — core build logic extracted from Build-Module.ps1.
#  Inherits PsCraft for module-discovery utilities.
class BuildOrchestrator : PsCraft {
  [string]    $Path
  [string[]]  $RequiredModules
  [System.Management.Automation.PSCmdlet]  $Cmdlet
  [System.Management.Automation.ModuleType]    $ModuleType = 'Script'
  [bool]      $HasBinarySrc = $false
  [BuildContext] $Context              # Dependency injection of build context
  [scriptblock] $PSakeScriptBlock = $null
  [BuildSummary] $BuildSummary = $null
  hidden $_runner   # [ThreadRunner] — typed at runtime; cliHelper.core type not parse-time resolvable as field
  hidden $_logger   # [Logger]       — typed at runtime; cliHelper.logger type not parse-time resolvable as field
  hidden [string] $_logDir

  BuildOrchestrator([string]$path, [string[]]$tasks, [string[]]$requiredModules, [System.Management.Automation.PSCmdlet]$cmdlet) {
    $this.Path = $path
    $this.TaskList = [System.Collections.Generic.List[string]]::new();
    if ($tasks) { $this.TaskList.AddRange($tasks) }
    $this.RequiredModules = $requiredModules
    $this.Cmdlet = $cmdlet
    $this.Context = [BuildContext]::new([IO.DirectoryInfo]::new($path).BaseName, $path, '0.0.0')
    $this.DetectModuleType()
    try { $this._runner = [ThreadRunner]::new() } catch { $this._runner = $null }
    $this.Init_Logger()
  }

  # Constructor with explicit BuildContext injection (preferred)
  BuildOrchestrator([string]$path, [string[]]$tasks, [string[]]$requiredModules, [System.Management.Automation.PSCmdlet]$cmdlet, [BuildContext]$context) {
    $this.Path = $path
    $this.TaskList = [System.Collections.Generic.List[string]]::new();
    if ($tasks) { $this.TaskList.AddRange($tasks) }
    $this.RequiredModules = $requiredModules
    $this.Cmdlet = $cmdlet
    $this.Context = $context
    $this.DetectModuleType()
    $srcPath = [IO.Path]::Combine($this.Path, 'src')
    $this.HasBinarySrc = [IO.Directory]::Exists($srcPath)

    if ($this.HasBinarySrc) {
      $csprojFiles = Get-ChildItem $srcPath -Filter '*.csproj' -ErrorAction Ignore
      if ($csprojFiles) {
        $this.ModuleType = 'Binary'
      }
    }
    try { $this._runner = [ThreadRunner]::new() } catch { $this._runner = $null }
    $this.Init_Logger()
  }

  hidden [void] Init_Logger() {
    $this._logDir = [IO.Path]::Combine($this.Context.BuildOutputPath, 'logs')
    try {
      if (!(Test-Path $this._logDir)) { New-Item -ItemType Directory -Path $this._logDir -Force -ea Ignore | Out-Null }
      $this._logger = [Logger]::new($this._logDir)
      $this._logger.AddLogAppender([ConsoleAppender]::new())
      $runId = $this.Context.RunId
      if ([string]::IsNullOrWhiteSpace($runId)) { $runId = 'build' }
      $this._logger.AddLogAppender([JsonAppender]::new([IO.Path]::Combine($this._logDir, "build-$runId.json")))
      # $this._logger.LogType = [BuildLogEntry]  # Requires BuildLogEntry : LogEntry (see class comment above)
    } catch {
      $this._logger = [NullLogger]::new()
    }
  }

  [void] Dispose() {
    try {
      if ($null -ne $this._logger -and !$this._logger.IsDisposed) {
        $this._logger.LogInfoLine("Build session ended.")
        $this._logger.Dispose()
      }
    } catch {
      [BuildLog]::WriteWarning("Error disposing logger: $($_ | Format-List * -Force | Out-String)")
    }
    try { $this._runner = $null } catch { $null }
  }

  [void] DetectModuleType() {
    $srcPath = [IO.Path]::Combine($this.Path, 'src')
    if ([IO.Directory]::Exists($srcPath) -and (Get-ChildItem $srcPath -Filter '*.csproj' -ErrorAction Ignore)) {
      $this.ModuleType = 'Binary'
      $this.HasBinarySrc = $true
      return
    }

    $cimPath = [IO.Path]::Combine($this.Path, 'Cim')
    if ([IO.Directory]::Exists($cimPath) -and (Get-ChildItem $cimPath -Filter '*.cdxml' -ErrorAction Ignore)) {
      $this.ModuleType = 'Cim'
      return
    }

    $mName = [IO.DirectoryInfo]::new($this.Path).BaseName
    if (Test-Path -Path ([IO.Path]::Combine($this.Path, "$mName.psm1")) -ErrorAction Ignore) {
      $this.ModuleType = 'Script'
      return
    }

    # Check manifest file to see if it lists a RootModule/NestedModules
    $psd1 = [IO.Path]::Combine($this.Path, "$mName.psd1")
    if (Test-Path -Path $psd1 -ErrorAction Ignore) {
      try {
        $manifest = Import-PowerShellDataFile -Path $psd1 -ErrorAction Ignore
        $rootModule = $manifest.RootModule ?? $manifest.NestedModules
        if ($rootModule) {
          $rootModuleStr = $rootModule -join ''
          if ($rootModuleStr -like "*.dll") {
            $this.ModuleType = 'Binary'
            return
          }
          if ($rootModuleStr -like "*.cdxml") {
            $this.ModuleType = 'Cim'
            return
          }
          if ($rootModuleStr -like "*.psm1") {
            $this.ModuleType = 'Script'
            return
          }
        }
        $this.ModuleType = 'Manifest'
        return
      } catch {
        [BuildLog]::WriteSevere("Error importing manifest file: $($_ | Format-List * -Force | Out-String)")
      }
    }

    # Default fallback
    $this.ModuleType = 'Script'
  }

  # ── Compilation dispatch and methods ─────────────────────────────────────────
  [bool] Compile() {
    [BuildLog]::WriteHeading("Compiling module type: $($this.ModuleType)")
    [BuildLog]::WriteStep("Formatting module code...")
    $mod = [PsModule]::Load($this.Path)
    $mod.FormatCode()
    $success = switch ($this.ModuleType) {
      "Script" { $this.CompileScriptModule() }
      "Binary" { $this.CompileBinaryModule() }
      "Cim" { $this.CompileCimModule() }
      "Manifest" { $this.CompileManifestModule() }
      default {
        [BuildLog]::WriteSevere("Unknown ModuleType: $($this.ModuleType)")
        $false
      }
    }
    return $success
  }

  [bool] CompileScriptModule() {
    try {
      $mName = $this.Context.ProjectName
      $versionDir = $this.Context.GetVersionedOutputPath()

      $this._logger.LogInfoLine("Compile started: $mName v$($this.Context.BuildNumber) -> $versionDir")

      New-Item -Path $versionDir -ItemType Directory -Force -ea Ignore | Out-Null

      $filesToCopy = @()
      $items = @('en-US', 'Private', 'Public', 'LICENSE', 'README.md', "$mName.psm1")
      foreach ($item in $items) {
        $p = [IO.Path]::Combine($this.Path, $item)
        if (Test-Path -Path $p -ea Ignore) {
          $filesToCopy += $p
        }
      }

      [BuildLog]::WriteStep("Copying script module files (parallel)...")
      $this.CopyFilesParallel($filesToCopy, $versionDir, $null)
      $this._logger.LogInfoLine("Compile complete. Files: $($filesToCopy.Count)")

      $mod = [PsModule]::Load($this.Path)
      [void][PsModuleData]::ReplaceTemplates(@($mod.Data))
      $mod.Save()

      $ModuleManifest = [IO.FileInfo]::new([IO.Path]::Combine($versionDir, "$mName.psd1"))
      if (!$ModuleManifest.Exists) {
        $srcManifest = [IO.Path]::Combine($this.Path, "$mName.psd1")
        if (Test-Path -Path $srcManifest -ea Ignore) {
          Copy-Item -Path $srcManifest -Destination $ModuleManifest.FullName -Force
        }
      }

      if ($ModuleManifest.Exists) {
        $publicFunctionsPath = [IO.Path]::Combine($this.Path, 'Public')
        $publicFunctionNames = @()
        if (Test-Path -Path $publicFunctionsPath) {
          $publicFunctionNames = Get-ChildItem -Path $publicFunctionsPath -Filter '*.ps1' | Select-Object -ExpandProperty BaseName
        }

        $manifestContent = Get-Content -Path $ModuleManifest.FullName -Raw
        $funcsExport = if ($publicFunctionNames.Count -gt 0) { "'$($publicFunctionNames -join "',`n        '")'" } else { '$null' }
        $manifestContent = $manifestContent.Replace("'<FunctionsToExport>'", $funcsExport)
        $manifestContent = $manifestContent.Replace('<ModuleVersion>', $this.Context.BuildNumber.ToString())
        $manifestContent = $manifestContent.Replace('<ReleaseNotes>', $this.Context.ReleaseNotes)
        $manifestContent = $manifestContent.Replace('<Year>', [Datetime]::Now.Year)

        $manifestContent | Set-Content -Path $ModuleManifest.FullName -Force

        [BuildLog]::WriteStatus("Script module compiled successfully", 'success')
        return $true
      } else {
        [BuildLog]::WriteSevere("Module manifest file not found: $($ModuleManifest.FullName)")
        return $false
      }
    } catch {
      $this._logger.LogFatalLine("Step failed: $($_.Exception.Message)", $_.Exception)
      [BuildLog]::WriteSevere("Error during script module compilation: $($_ | Format-List * -Force | Out-String)")
      return $false
    }
  }

  [bool] CompileBinaryModule() {
    if ($this.ModuleType -ne 'Binary') {
      [BuildLog]::WriteWarning("Module is not a binary module type")
      return $false
    }

    $srcPath = [IO.Path]::Combine($this.Path, 'src')
    if (![IO.Directory]::Exists($srcPath)) {
      [BuildLog]::WriteSevere("Binary module source directory not found: $srcPath")
      return $false
    }

    try {
      $dotnetVer = dotnet --version 2>&1
      [BuildLog]::WriteStatus("Using dotnet $dotnetVer", 'success')
    } catch {
      [BuildLog]::WriteSevere(".NET SDK is not installed or not in PATH. Required for binary module compilation.")
      return $false
    }

    try {
      [BuildLog]::WriteStep("Compiling binary module at: $srcPath")

      $mName = $this.Context.ProjectName
      $versionDir = $this.Context.GetVersionedOutputPath()
      $this._logger.LogInfoLine("Compile started: $mName v$($this.Context.BuildNumber) -> $versionDir")

      New-Item -Path $versionDir -ItemType Directory -Force -ea Ignore | Out-Null

      Push-Location $srcPath
      $buildOutput = & dotnet build -c Release -o $versionDir 2>&1
      Pop-Location

      if ($LASTEXITCODE -ne 0) {
        [BuildLog]::WriteSevere("Binary module compilation failed:`n$buildOutput")
        return $false
      }

      $filesToCopy = @()
      $items = @('LICENSE', 'README.md')
      foreach ($item in $items) {
        $p = [IO.Path]::Combine($this.Path, $item)
        if (Test-Path -Path $p -ea Ignore) {
          $filesToCopy += $p
        }
      }
      $this.CopyFilesParallel($filesToCopy, $versionDir, $null)
      $this._logger.LogInfoLine("Compile complete. Files: $($filesToCopy.Count)")

      $ModuleManifest = [IO.FileInfo]::new([IO.Path]::Combine($versionDir, "$mName.psd1"))
      if (!$ModuleManifest.Exists) {
        $srcManifest = [IO.Path]::Combine($this.Path, "$mName.psd1")
        if (Test-Path -Path $srcManifest -ea Ignore) {
          Copy-Item -Path $srcManifest -Destination $ModuleManifest.FullName -Force
        }
      }

      if ($ModuleManifest.Exists) {
        $manifestContent = Get-Content -Path $ModuleManifest.FullName -Raw
        $manifestContent = $manifestContent.Replace('<ModuleVersion>', $this.Context.BuildNumber.ToString())
        $manifestContent = $manifestContent.Replace('<ReleaseNotes>', $this.Context.ReleaseNotes)
        $manifestContent = $manifestContent.Replace('<Year>', [Datetime]::Now.Year)

        $manifestContent | Set-Content -Path $ModuleManifest.FullName -Force
      }

      [BuildLog]::WriteStatus("Binary module compiled successfully", 'success')
      return $true
    } catch {
      $this._logger.LogFatalLine("Step failed: $($_.Exception.Message)", $_.Exception)
      [BuildLog]::WriteSevere("Error during binary module compilation: $($_ | Format-List * -Force | Out-String)")
      return $false
    }
  }

  [bool] CompileCimModule() {
    try {
      $mName = $this.Context.ProjectName
      $versionDir = $this.Context.GetVersionedOutputPath()
      $this._logger.LogInfoLine("Compile started: $mName v$($this.Context.BuildNumber) -> $versionDir")

      New-Item -Path $versionDir -ItemType Directory -Force -ea Ignore | Out-Null

      $filesToCopy = @()
      $items = @('Cim', 'LICENSE', 'README.md')
      foreach ($item in $items) {
        $p = [IO.Path]::Combine($this.Path, $item)
        if (Test-Path -Path $p -ea Ignore) {
          $filesToCopy += $p
        }
      }

      [BuildLog]::WriteStep("Copying CIM module files (parallel)...")
      $this.CopyFilesParallel($filesToCopy, $versionDir, $null)
      $this._logger.LogInfoLine("Compile complete. Files: $($filesToCopy.Count)")

      $ModuleManifest = [IO.FileInfo]::new([IO.Path]::Combine($versionDir, "$mName.psd1"))
      if (!$ModuleManifest.Exists) {
        $srcManifest = [IO.Path]::Combine($this.Path, "$mName.psd1")
        if (Test-Path -Path $srcManifest -ea Ignore) {
          Copy-Item -Path $srcManifest -Destination $ModuleManifest.FullName -Force
        }
      }

      if ($ModuleManifest.Exists) {
        $manifestContent = Get-Content -Path $ModuleManifest.FullName -Raw
        $manifestContent = $manifestContent.Replace('<ModuleVersion>', $this.Context.BuildNumber.ToString())
        $manifestContent = $manifestContent.Replace('<ReleaseNotes>', $this.Context.ReleaseNotes)
        $manifestContent = $manifestContent.Replace('<Year>', [Datetime]::Now.Year)

        $manifestContent | Set-Content -Path $ModuleManifest.FullName -Force

        [BuildLog]::WriteStatus("CIM module compiled successfully", 'success')
        return $true
      } else {
        [BuildLog]::WriteSevere("Module manifest file not found: $($ModuleManifest.FullName)")
        return $false
      }
    } catch {
      $this._logger.LogFatalLine("Step failed: $($_.Exception.Message)", $_.Exception)
      [BuildLog]::WriteSevere("Error during CIM module compilation: $($_ | Format-List * -Force | Out-String)")
      return $false
    }
  }

  [bool] CompileManifestModule() {
    try {
      $mName = $this.Context.ProjectName
      $versionDir = $this.Context.GetVersionedOutputPath()
      $this._logger.LogInfoLine("Compile started: $mName v$($this.Context.BuildNumber) -> $versionDir")

      New-Item -Path $versionDir -ItemType Directory -Force -ea Ignore | Out-Null

      $filesToCopy = @()
      $items = @('LICENSE', 'README.md')
      foreach ($item in $items) {
        $p = [IO.Path]::Combine($this.Path, $item)
        if (Test-Path -Path $p -ea Ignore) {
          $filesToCopy += $p
        }
      }

      [BuildLog]::WriteStep("Copying Manifest module files (parallel)...")
      $this.CopyFilesParallel($filesToCopy, $versionDir, $null)
      $this._logger.LogInfoLine("Compile complete. Files: $($filesToCopy.Count)")

      $ModuleManifest = [IO.FileInfo]::new([IO.Path]::Combine($versionDir, "$mName.psd1"))
      if (!$ModuleManifest.Exists) {
        $srcManifest = [IO.Path]::Combine($this.Path, "$mName.psd1")
        if (Test-Path -Path $srcManifest -ea Ignore) {
          Copy-Item -Path $srcManifest -Destination $ModuleManifest.FullName -Force
        }
      }

      if ($ModuleManifest.Exists) {
        $manifestContent = Get-Content -Path $ModuleManifest.FullName -Raw
        $manifestContent = $manifestContent.Replace('<ModuleVersion>', $this.Context.BuildNumber.ToString())
        $manifestContent = $manifestContent.Replace('<ReleaseNotes>', $this.Context.ReleaseNotes)
        $manifestContent = $manifestContent.Replace('<Year>', [Datetime]::Now.Year)

        $manifestContent | Set-Content -Path $ModuleManifest.FullName -Force

        [BuildLog]::WriteStatus("Manifest module compiled successfully", 'success')
        return $true
      } else {
        [BuildLog]::WriteSevere("Module manifest file not found: $($ModuleManifest.FullName)")
        return $false
      }
    } catch {
      $this._logger.LogFatalLine("Step failed: $($_.Exception.Message)", $_.Exception)
      [BuildLog]::WriteSevere("Error during Manifest module compilation: $($_ | Format-List * -Force | Out-String)")
      return $false
    }
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
    try {
      [AnsiConsole]::Status().Start('[yellow]Preparing package feeds...[/]', [Action[object]] {
          param($ctx)
          $ctx.Spinner = [Spinner]::Known.Dots
          $PackageProviders = Get-PackageProvider -ListAvailable -ea Ignore -Verbose:$false
          @('NuGet', 'PowerShellGet') | ForEach-Object {
            $ctx.Update("Checking package provider: $_")
            if (!$PackageProviders.Name.Contains($_)) {
              $ctx.Status = "Installing $_ provider..."
              Install-PackageProvider -Name $_ -Force -ea Ignore -Verbose:$false
            }
            Get-PackageProvider -Name $_ -ForceBootstrap -Verbose:$false -ea Ignore
          }

          $ctx.Update("Registering PSGallery...")
          if ($null -eq (Get-PSRepository -Name PSGallery -ea Ignore -Verbose:$false)) {
            Unregister-PSRepository -Name PSGallery -Verbose:$false -ea Ignore
            Register-PSRepository -Default -InstallationPolicy Trusted
          }
          if ((Get-PSRepository -Name PSGallery -ea Ignore).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -Verbose:$false -ea Ignore
          }
          $ctx.Status = '[green]Package feeds ready[/]'
        }
      )
    } catch {
      # Fallback to original implementation
      $PackageProviders = Get-PackageProvider -ListAvailable -ea Ignore -Verbose:$false
      @('NuGet', 'PowerShellGet') | ForEach-Object {
        if (!$PackageProviders.Name.Contains($_)) { Install-PackageProvider -Name $_ -Force }
        Get-PackageProvider -Name $_ -ForceBootstrap -Verbose:$false
      }
      if ($null -eq (Get-PSRepository -Name PSGallery -ea Ignore -Verbose:$false)) {
        Unregister-PSRepository -Name PSGallery -Verbose:$false -ea Ignore
        Register-PSRepository -Default -InstallationPolicy Trusted
      }
      if ((Get-PSRepository -Name PSGallery -ea Ignore).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -Verbose:$false
      }
    }
  }

  # ── Dependency resolution ───────────────────────────────────────────────────
  [void] ResolveBuildRequirements() {
    $psd1 = [System.IO.Path]::Combine($this.Path, "$([IO.DirectoryInfo]::new($this.Path).BaseName).psd1")
    if ([IO.File]::Exists($psd1)) {
      $data = Import-PowerShellDataFile -Path $psd1 -ErrorAction Stop
      $this.RequiredModules = ($data.RequiredModules + $this.RequiredModules) | Select-Object -Unique
    }
    $IsConnected = $( try {
        [Net.NetworkInformation.Ping]::new().Send('www.powershellgallery.com').Status -eq [Net.NetworkInformation.IPStatus]::Success
      } catch { $false }
    )

    [BuildLog]::WriteStep("Resolving build dependencies (parallel)...")
    $this._logger.LogInfoLine("Resolving dependencies: $($this.RequiredModules -join ', ')")
    $checkResults = $this.CheckModulesParallel()
    $missingMods = @($checkResults.Missing)

    if ($missingMods.Count -gt 0) {
      $this._logger.LogWarnLine("Missing modules: $($missingMods -join ', ')")
      if ($IsConnected) {
        try {
          [AnsiConsole]::Status().Start('[yellow]Installing missing dependencies...[/]', [Action[object]] {
              param($ctx)
              $ctx.Spinner = [Spinner]::Known.Dots
              foreach ($name in $missingMods) {
                $ctx.Update("Installing $name ...")
                Install-Module -Name $name -Verbose:$false -Scope CurrentUser -Force -ea Continue
              }
            }
          )
        } catch {
          foreach ($name in $missingMods) {
            [BuildLog]::WriteStatus("Installing module: $name", 'info')
            Install-Module -Name $name -Verbose:$false -Scope CurrentUser -Force -ea Continue
          }
        }
      } else {
        [BuildLog]::WriteWarning("Offline. Cannot install missing modules: $($missingMods -join ', ')")
      }
    }

    $psds = (Get-Module -Name $this.RequiredModules -ListAvailable -Verbose:$false -ErrorAction Ignore).Path | Sort-Object -Unique { Split-Path $_ -Leaf }
    $psds | Import-Module -Verbose:$false -ea Stop
  }

  # ── Parallel module checking with ThreadRunner ─────────────────────────────
  [hashtable] CheckModulesParallel() {
    $results = @{
      Installed = @()
      Missing   = @()
      Failed    = @()
    }

    if ($this.RequiredModules.Count -eq 0) { return $results }

    try {
      if ($null -eq $this._runner) { throw "ThreadRunner unavailable" }
      $runner = [ThreadRunner]::new() # Create a fresh runner for this batch

      # Queue parallel module checks
      foreach ($moduleName in $this.RequiredModules) {
        $runner.AddJob("Check $moduleName", {
            param($name)
            $installed = Get-Module -Name $name -ListAvailable -Verbose:$false -ErrorAction Ignore
            return [PSCustomObject]@{
              Name      = $name
              Installed = $null -ne $installed
              Versions  = $installed.Version -as [version[]]
            }
          }, $moduleName)
      }

      # Wait for all tasks and collect results
      $checkResults = $runner.ExecuteAll()
      foreach ($result in $checkResults) {
        if ($result.Success) {
          $out = $result.Output
          if ($out.Installed) {
            $results.Installed += $out.Name
          } else {
            $results.Missing += $out.Name
          }
        } else {
          $results.Failed += $result.Name
        }
      }
    } catch {
      [BuildLog]::WriteSevere("$($_ | Format-List * -Force | Out-String)")
      # ThreadRunner unavailable — fall back to sequential
      [BuildLog]::WriteWarning("ThreadRunner unavailable; using sequential checks")
      foreach ($moduleName in $this.RequiredModules) {
        if (Get-Module -Name $moduleName -ListAvailable -Verbose:$false -ErrorAction Ignore) {
          $results.Installed += $moduleName
        } else {
          $results.Missing += $moduleName
        }
      }
    }

    return $results
  }

  # ── Parallel file copy with progress tracking ──────────────────────────────
  [void] CopyFilesParallel([string[]]$FilePaths, [string]$DestinationPath, [ScriptBlock]$ProgressCallback) {
    if ($FilePaths.Count -eq 0) { return }
    $completed = 0
    try {
      if ($null -eq $this._runner) { throw "ThreadRunner unavailable" }
      $runner = [ThreadRunner]::new() # Fresh runner for file copy

      $totalFiles = $FilePaths.Count

      foreach ($filePath in $FilePaths) {
        $fileName = [IO.Path]::GetFileName($filePath)
        $runner.AddJob("Copy $fileName", {
            param($args)
            $src = $args[0]
            $dst = $args[1]
            Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
            return [PSCustomObject]@{ Source = $src; Success = $? }
          }, @($filePath, $DestinationPath))
      }

      # Monitor progress
      $jobResults = $runner.ExecuteAll()
      foreach ($result in $jobResults) {
        if ($result.Success) {
          $completed++
          if ($ProgressCallback) {
            & $ProgressCallback -Progress ($completed / $totalFiles * 100)
          }
        }
      }
    } catch {
      [BuildLog]::WriteSevere("$($_ | Format-List * -Force | Out-String)")
      # ThreadRunner unavailable — fall back to sequential copy
      [BuildLog]::WriteWarning("ThreadRunner unavailable; using sequential file copy")
      foreach ($filePath in $FilePaths) {
        Copy-Item -Path $filePath -Destination $DestinationPath -Force -ErrorAction Continue
        if ($ProgressCallback) {
          $completed++
          & $ProgressCallback -Progress ($completed / $FilePaths.Count * 100)
        }
      }
    }
  }

  # ── Dispatch ────────────────────────────────────────────────────────────────
  # Initialize build context with project-specific data and export to environment
  [void] InitializeBuildContext([version]$BuildNumber) {
    $this.Context.BuildNumber = $BuildNumber
    # Export context to environment for PSake script block compatibility
    $this.Context.ExportToEnvironment()
  }

  [int] Run([string[]]$tasks) {
    # Initialize the build context with version info
    $psd1Path = [IO.Path]::Combine($this.Path, "$([IO.DirectoryInfo]::new($this.Path).BaseName).psd1")
    $buildNumber = '0.0.0'
    if ([IO.File]::Exists($psd1Path)) {
      try {
        $manifest = Import-PowerShellDataFile -Path $psd1Path -ErrorAction Ignore
        if ($manifest.ModuleVersion) { $buildNumber = $manifest.ModuleVersion }
      } catch {
        $null = $this.Cmdlet.WriteWarning("Failed to read module version from manifest: $_. Using default 0.0.0")
      }
    }

    # Initialize and export context (replaces manual environment variable setting)
    $this.InitializeBuildContext([version]$buildNumber)

    # Call Set-BuildVariables if it exists (for backwards compatibility)
    if (Get-Command 'Set-BuildVariables' -ErrorAction Ignore) {
      Set-BuildVariables $this.Path $this.Context.RunId
    }

    try {
      [AnsiConsole]::Progress().Start([Action[object]] {
          param($ctx)
          $cleanTask = $ctx.AddTask('[cyan]Clean[/]', $true, 100)
          $compileTask = $ctx.AddTask('[cyan]Compile[/]', $true, 100)
          $testTask = $ctx.AddTask('[cyan]Test[/]', $true, 100)

          if ('Clean' -in $tasks) { $this.Clean(); $cleanTask.Value = 100 }
          if ('Compile' -in $tasks) { $this.Compile(); $compileTask.Value = 100 }
          if ('Test' -in $tasks) { $this.Test(); $testTask.Value = 100 }
        })
    } catch {
      # Fallback: plain sequential execution with BuildLog step headers
      if ('Clean' -in $tasks) { [BuildLog]::WriteHeading('Clean'); $this.Clean() }
      if ('Compile' -in $tasks) { [BuildLog]::WriteHeading('Compile'); $this.Compile() }
      if ('Test' -in $tasks) { [BuildLog]::WriteHeading('Test'); $this.Test() }
    }

    return 0
  }

  [void] Clean() {
    $versionDir = $this.Context.GetVersionedOutputPath()
    if (Test-Path $versionDir -ea Ignore) {
      Remove-Item $versionDir -Recurse -Force -ea Ignore
    }
  }

  [void] Test() {
    # To be implemented in Phase 5
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
        # Use BuildContext properties instead of environment variables
        $ModuleName = $this.Context.ProjectName
        $BuildNumber = $this.Context.BuildNumber.ToString()
        $ModulePath = $this.Context.GetVersionedOutputPath()
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

    # Clear the build context from environment
    $this.Context.ClearEnvironment()

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

  [string] ToString() {
    return "[BuildOrchestrator] $($this.Context.ProjectName) tasks=$($this.TaskList -join ',')"
  }
}
