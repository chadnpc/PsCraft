using namespace System.IO
using namespace System.ComponentModel
using namespace System.Collections.Generic
using namespace System.Management.Automation
using namespace System.Collections.ObjectModel
using namespace System.Management.Automation.Language

#Requires -RunAsAdministrator
#Requires -Modules PsModuleBase, cliHelper.core
#Requires -Psedition Core

enum SaveOptions {
  AcceptAllChangesAfterSave # After changes are saved, we resets change tracking.
  DetectChangesBeforeSave # Before changes are saved, the DetectChanges method is called to synchronize Objects.
  None # Changes are saved without the DetectChanges or the AcceptAllChangesAfterSave methods being called. This can be equivalent of Force, as it can ovewrite objects.
}
enum PSEdition {
  Desktop
  Core
}

#region    ModuleManager
# .SYNOPSIS
# ModuleManager Class
# .EXAMPLE
# $handler = [ModuleManager]::new("MyModule", "Path/To/MyModule.psm1")
# if ($handler.TestModulePath()) {
#    $handler.ImportModule()
#    $functions = $handler.ListExportedFunctions()
#    Write-Host "Exported functions: $functions"
#  } else {
#    Write-Host "Module not found at specified path"
#  }
#  TODO: Add more robust example. (This shit can do way much more.)

class ModuleManager : Microsoft.PowerShell.Commands.ModuleCmdletBase {
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

  ModuleManager() {}
  ModuleManager([string]$RootPath) { [void][ModuleManager]::From($RootPath, $this) }
  static [ModuleManager] Create() { return [ModuleManager]::From((Resolve-Path .).Path, $null) }
  static [ModuleManager] Create([string]$RootPath) { return [ModuleManager]::From($RootPath, $null) }

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
    ForEach ($file in $filesToCheck) {
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
        [ModuleManager]::UpdateModule($moduleName, $Version)
      }
    }
  }
  static [void] InstallModule([string]$moduleName, [string]$Version) {
    # There are issues with pester 5.4.1 syntax, so I'll keep using -SkipPublisherCheck.
    # https://stackoverflow.com/questions/51508982/pester-sample-script-gets-be-is-not-a-valid-should-operator-on-windows-10-wo
    $IsPester = $moduleName -eq 'Pester'
    if ($IsPester) { [void][ModuleManager]::RemoveOld($moduleName) }
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
  static [ModuleManager] From([string]$RootPath, [ref]$o) {
    $b = [ModuleManager]::new();
    [Net.ServicePointManager]::SecurityProtocol = [ModuleManager]::GetSecurityProtocol();
    [Environment]::SetEnvironmentVariable('IsAC', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('IsCI', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('TF_BUILD'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('RUN_ID', $(if ([bool][int]$env:IsAC -or $env:CI -eq "true") { [Environment]::GetEnvironmentVariable('GITHUB_RUN_ID') }else { [Guid]::NewGuid().Guid.substring(0, 21).replace('-', [string]::Join('', (0..9 | Get-Random -Count 1))) + '_' }), [System.EnvironmentVariableTarget]::Process);
    [ModuleManager]::Useverbose = (Get-Variable VerbosePreference -ValueOnly -Scope global) -eq "continue"
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
    [ModuleManager]::LocalizedData = Read-ModuleData -File $b.dataFile
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
  static [void] ValidatePath([string]$path) {
    $InvalidPathChars = [Path]::GetInvalidPathChars()
    $InvalidCharsRegex = "[{0}]" -f [regex]::Escape($InvalidPathChars)
    if ($Path -match $InvalidCharsRegex) {
      throw [InvalidEnumArgumentException]::new("The path string contains invalid characters.")
    }
  }
  static [bool] IsAdmin() {
    $HostOs = [ModuleManager]::GetHostOs()
    $isAdmn = switch ($HostOs) {
      "Windows" { (New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator); break }
      "Linux" { (& id -u) -eq 0; break }
      "MacOSX" { Write-Warning "MacOSX !! idk how to solve this one!"; $false; break }
      Default {
        Write-Warning "[ModuleManager]::IsAdmin? : OSPlatform $((Get-Variable 'PSVersionTable' -ValueOnly).Platform) | $HostOs is not yet supported"
        throw "UNSUPPORTED_OS"
      }
    }
    return $isAdmn
  }
}

class PsModule : IDisposable {
  [ValidateNotNullOrEmpty()] [String]$Name;
  [ValidateNotNullOrEmpty()] [IO.DirectoryInfo]$Path;
  [Collection[PsModuleData]] $Data;
  [List[ModuleFolder]] $Folders;
  [List[ModuleFile]] $Files;
  static [hashtable] $Config

  PsModule() {
    [PsModule]::Create($null, $null, [ref]$this)
  }
  PsModule([string]$Name) {
    [PsModule]::Create($Name, $null, [ref]$this)
  }
  PsModule([string]$Name, [IO.DirectoryInfo]$Path) {
    [PsModule]::Create($Name, $Path, [ref]$this)
  }
  static [PsModule] Create([string]$Name) { return [PsModule]::Create($Name, $null) }

  static [PsModule] Create([string]$Name, [string]$Path) {
    $b = [PsModuleBase]::GetunResolvedPath($Path); $p = [IO.Path]::Combine($b, $Name);
    $d = [IO.DirectoryInfo]::new($p); if (![IO.Directory]::Exists($d)) {
      return [PsModule]::new($d.BaseName, $d.Parent)
    }
    Write-Host "[WIP] Load Module from $p" -f Blue
    return [PsModule]::Load($d)
  }
  static hidden [PsModule] Create([string]$Name, [IO.DirectoryInfo]$Path, [ref]$o) {
    if ($null -eq $o.Value -and [PsModule]::_n) { [PsModule]::_n = $false; $n = [PsModule]::new(); $o = [ref]$n }
    if ($null -ne [PsModule]::Config) {
      # Config includes:
      # - Build steps
      # - Params ...
    }
    $o.Value.Name = [string]::IsNullOrWhiteSpace($Name) ? [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetRandomFileName()) : $Name
    ($mName, $_umroot) = [string]::IsNullOrWhiteSpace($Path.FullName) ? ($o.Value.Name, $Path.FullName) : ($o.Value.Name, "")
    $mroot = [Path]::Combine([PsModuleBase]::GetunResolvedPath($(
          switch ($true) {
            $(![string]::IsNullOrWhiteSpace($_umroot)) { $_umroot; break }
            $o.Value.Path {
              if ([Path]::GetFileNameWithoutExtension($o.Value.Path) -ne $mName) {
                $o.Value.Path = [FileInfo][Path]::Combine(([Path]::GetDirectoryName($o.Value.Path) | Split-Path), "$mName.psd1")
              }
              [Path]::GetDirectoryName($o.Value.Path);
              break
            }
            Default { $(Resolve-Path .).Path }
          })
      ), $mName)
    [void][ModuleManager]::validatePath($mroot); $o.Value.Path = $mroot
    $o.Value.Files = [List[ModuleFile]]::new()
    $o.Value.Folders = [List[ModuleFolder]]::new()
    $mtest = [Path]::Combine($mroot, 'Tests');
    $workflows = [Path]::Combine($mroot, '.github', 'workflows')
    $dr = @{
      root      = $mroot
      tests     = [Path]::Combine($mroot, 'Tests');
      public    = [Path]::Combine($mroot, 'Public')
      private   = [Path]::Combine($mroot, 'Private')
      LocalData = [Path]::Combine($mroot, (Get-Culture).Name) # The purpose of this folder is to store localized content for your module, such as help files, error messages, or any other text that needs to be displayed in different languages.
      workflows = $workflows
      # Add more here. you can access them like: $this.Folders.Where({ $_.Name -eq "root" }).value.FullName
    };
    $dr.Keys.ForEach({ $o.Value.Folders += [ModuleFolder]::new($_, $dr[$_]) })
    $fl = @{
      Path             = [Path]::Combine($mroot, "$mName.psd1")
      Tester           = [Path]::Combine($mroot, "Test-Module.ps1")
      Builder          = [Path]::Combine($mroot, "build.ps1")
      License          = [Path]::Combine($mroot, "LICENSE")
      Readme           = [Path]::Combine($mroot, "README.md")
      Manifest         = [Path]::Combine($mroot, "$mName.psd1")
      LocalData        = [Path]::Combine($dr["LocalData"], "$mName.strings.psd1")
      rootLoader       = [Path]::Combine($mroot, "$mName.psm1")
      ModuleTest       = [Path]::Combine($mtest, "$mName.Module.Tests.ps1")
      FeatureTest      = [Path]::Combine($mtest, "$mName.Features.Tests.ps1")
      ScriptAnalyzer   = [Path]::Combine($mroot, "PSScriptAnalyzerSettings.psd1")
      IntegrationTest  = [Path]::Combine($mtest, "$mName.Integration.Tests.ps1")
      DelWorkflowsyaml = [Path]::Combine($workflows, 'delete_old_workflow_runs.yaml')
      Codereviewyaml   = [Path]::Combine($workflows, 'codereview.yaml')
      Publishyaml      = [Path]::Combine($workflows, 'publish.yaml')
      GitIgnore        = [Path]::Combine($mroot, ".gitignore")
      CICDyaml         = [Path]::Combine($workflows, 'build_module.yaml')
      DotEnv           = [Path]::Combine($mroot, ".env")
      # Add more here
    };
    $fl.Keys.ForEach({ $o.Value.Files += [ModuleFile]::new($_, $fl[$_]) })
    $o.Value.Data = [PsModuleData]::Create($o.Value.Name, $o.Value.Path, $o.Value.Files)
    return $o.Value
  }
  [void] Save() {
    $this.Save([SaveOptions]::None)
  }
  [void] Save([SaveOptions]$Options) {
    if ([string]::IsNullOrWhiteSpace($this.Name)) {
      throw [System.ArgumentNullException]::New('$this.Name', "Make sure module Name is not empty")
    }
    $filestoFormat = $this.GetFiles().Where({ $_.Path.Extension -in ('.ps1', '.psd1', '.psm1') })
    $this.Data.Where({ $_.Key -in $filestoFormat.Name }).ForEach({ $_.Format() })
    $this.Data = [PsModuleData]::ReplaceTemplates($this.Data); $this.WritetoDisk($Options)
  }
  [void] Set([string]$Key, $Value) {
    $this.Data.Where({ $_.Key -eq $Key }).Set($Value);
  }
  [void] FormatCode() {
    [ModuleManager]::FormatCode($this)
  }
  [void] WritetoDisk([SaveOptions]$Options) {
    $Force = $Options -eq [SaveOptions]::None
    $debug = $(Get-Variable debugPreference -ValueOnly) -eq "Continue"
    Write-Host "[+] Create Module Directories ... " -ForegroundColor Green -NoNewline:(!$debug -as [SwitchParameter])
    $this.Folders | ForEach-Object {
      $nF = @(); $p = $_.value; While (!$p.Exists) { $nF += $p; $p = $p.Parent }
      [Array]::Reverse($nF);
      ForEach ($d in $nF) {
        New-Item -Path $d.FullName -ItemType Directory -Force:$Force
        if ($debug) { Write-Debug "Created Directory '$($d.FullName)'" }
      }
    }
    Write-Host "Done" -ForegroundColor Green

    Write-Host "[+] Create Module Files ... " -ForegroundColor Green -NoNewline:(!$debug -as [SwitchParameter])
    $this.GetFiles().ForEach({ [IO.File]::WriteAllText($_.Path, $_.Content, [System.Text.Encoding]::UTF8); if ($debug) { Write-Debug "Created $($_.Name)" } })
    $PM = @{}; $this.Data.Where({ $_.Attributes -contains "ManifestKey" }).ForEach({ $PM.Add($_.Key, $_.Value) })
    New-ModuleManifest @PM
    Write-Host "Done" -ForegroundColor Green
  }
  static [PsModule] Load([string]$Path) {
    return [PsModule]::Load($null, $Path)
  }
  static [PsModule] Load([string]$Name, [string]$Path) {
    # TODO: Add some Module Loading code Here
    throw "[PsModule]::Load(...) NOT IMPLEMENTED YET (WIP)"
  }
  [PsObject[]] GetFiles() {
    $KH = @{}; $this.Data.Where({ $_.Attributes -notcontains "ManifestKey" -and $_.Attributes -contains "FileContent" }).ForEach({ $KH[$_.Key] = $_.Value })
    $MF = $this.Files | Select-Object Name, @{l = "Path"; e = { $_.Value } }, @{l = "Content"; e = { $KH[$_.Name] } }
    return $MF
  }
  [void] Test() {
    # $this.Save()
    # .then run tests
    throw "`$psmodule.Test() is NOT IMPLEMENTED YET (WIP)"
  }
  [void] Publish() {
    $this.Publish('LocalRepo', [Path]::GetDirectoryName($Pwd))
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
    Publish-Module -Path $this.moduleDir -Repository $repoName
    Install-Module $this.Name -Repository $repoName
  }
  static [void] Publish ([string]$Path, [securestring]$ApiKey, [bool]$IncrementVersion ) {
    $moduleName = Split-Path $Path -Leaf
    $functions = Get-PsModuleFunctions $Path -PublicOnly
    if ($IncrementVersion) {
      $moduleFile = "$((Join-Path $path $moduleName)).psd1"
      $file = Import-PowerShellDataFile $moduleFile -Verbose:$false;
      [version]$version = ($file).ModuleVersion
      [version]$newVersion = "{0}.{1}.{2}" -f $version.Major, $version.Minor, ($version.Build + 1)
      Update-ModuleManifest -Path "$((Join-Path $Path $moduleName)).psd1" -FunctionsToExport $functions -ModuleVersion $newVersion;
    } else {
      Update-ModuleManifest -Path "$((Join-Path $Path $moduleName)).psd1" -FunctionsToExport $functions;
    }
    Publish-Module -Path $Path -NuGetApiKey $ApiKey;

    Write-Host "Module $moduleName Published " -f Green;
  }
  [void] Dispose() {
    if ($this.Path.Exists) { $this.Delete() }
  }
  [void] Delete() {
    Get-Module $this.Name | Remove-Module -Force -ErrorAction Ignore
    Remove-Item $this.Path.FullName -Recurse -Force
  }
}
class ParseResult {
  [Token[]]$Tokens
  [ScriptBlockAst]$AST
  [ParseError[]]$ParseErrors

  ParseResult([ParseError[]]$Errors, [Token[]]$Tokens, [ScriptBlockAst]$AST) {
    $this.ParseErrors = $Errors
    $this.Tokens = $Tokens
    $this.AST = $AST
  }
}

class AliasVisitor : System.Management.Automation.Language.AstVisitor {
  [string]$Parameter = $null
  [string]$Command = $null
  [string]$Name = $null
  [string]$Value = $null
  [string]$Scope = $null
  [System.Collections.Generic.HashSet[string]]$Aliases = @()

  # Parameter Names
  [System.Management.Automation.Language.AstVisitAction] VisitCommandParameter([System.Management.Automation.Language.CommandParameterAst]$ast) {
    $this.Parameter = $ast.ParameterName
    return [System.Management.Automation.Language.AstVisitAction]::Continue
  }

  # Parameter Values
  [System.Management.Automation.Language.AstVisitAction] VisitStringConstantExpression([System.Management.Automation.Language.StringConstantExpressionAst]$ast) {
    # The FIRST command element is always the command name
    if (!$this.Command) {
      $this.Command = $ast.Value
      return [System.Management.Automation.Language.AstVisitAction]::Continue
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
        return [System.Management.Automation.Language.AstVisitAction]::StopVisit
      } elseif ($this.Name -and $this.Scope -eq "Global") {
        return [System.Management.Automation.Language.AstVisitAction]::StopVisit
      }
      return [System.Management.Automation.Language.AstVisitAction]::Continue
    }
  }

  # The [Alias(...)] attribute on functions matters, but we can't export aliases that are defined inside a function
  [System.Management.Automation.Language.AstVisitAction] VisitFunctionDefinition([System.Management.Automation.Language.FunctionDefinitionAst]$ast) {
    @($ast.Body.ParamBlock.Attributes.Where{ $_.TypeName.Name -eq "Alias" }.PositionalArguments.Value).ForEach{
      if ($_) {
        $this.Aliases.Add($_)
      }
    }
    return [System.Management.Automation.Language.AstVisitAction]::SkipChildren
  }

  # Top-level commands matter, but only if they're alias commands
  [System.Management.Automation.Language.AstVisitAction] VisitCommand([System.Management.Automation.Language.CommandAst]$ast) {
    if ($ast.CommandElements[0].Value -imatch "(New|Set|Remove)-Alias") {
      $ast.Visit($this.ClearParameters())
      $Params = $this.GetParameters()
      # We COULD just remove it (even if we didn't add it) ...
      if ($Params.Command -ieq "Remove-Alias") {
        # But Write-Verbose for logging purposes
        if ($this.Aliases.Contains($this.Parameters.Name)) {
          Write-Verbose -Message "Alias '$($Params.Name)' is removed by line $($ast.Extent.StartLineNumber): $($ast.Extent.Text)"
          $this.Aliases.Remove($Params.Name)
        }
        # We don't need to export global aliases, because they broke out already
      } elseif ($Params.Name -and $Params.Scope -ine 'Global') {
        $this.Aliases.Add($this.Parameters.Name)
      }
    }
    return [System.Management.Automation.Language.AstVisitAction]::SkipChildren
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
#endregion ModuleManager

#region    Mainclass
# .SYNOPSIS
#  PsCraft: the giga-chad module builder and manager.
# .EXAMPLE
#  [PsModule]$module = New-PsModule "MyModule"   # Creates a new module named "MyModule" in $pwd
#  $builder = [PsCraft]::new($module.Path)
class PsCraft : PsModuleBase, ModuleManager {
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
}
#endregion Mainclass

# Types that will be available to users when they import the module.
$typestoExport = @(
  [moduleManager],
  [LocalPsModule],
  [PsModule],
  [PsCraft]
)
$TypeAcceleratorsClass = [PsObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
foreach ($Type in $typestoExport) {
  if ($Type.FullName -in $TypeAcceleratorsClass::Get.Keys) {
    $Message = @(
      "Unable to register type accelerator '$($Type.FullName)'"
      'Accelerator already exists.'
    ) -join ' - '

    [System.Management.Automation.ErrorRecord]::new(
      [System.InvalidOperationException]::new($Message),
      'TypeAcceleratorAlreadyExists',
      [System.Management.Automation.ErrorCategory]::InvalidOperation,
      $Type.FullName
    ) | Write-Warning
  }
}
# Add type accelerators for every exportable type.
foreach ($Type in $typestoExport) {
  $TypeAcceleratorsClass::Add($Type.FullName, $Type)
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
  Try {
    if ([string]::IsNullOrWhiteSpace($file.fullname)) { continue }
    . "$($file.fullname)"
  } Catch {
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