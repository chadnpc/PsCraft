using namespace System
using namespace System.IO
using namespace System.Text
using namespace System.Threading
using namespace system.reflection
using namespace System.ComponentModel
using namespace System.Collections.Generic
using namespace System.Management.Automation
using namespace System.Collections.ObjectModel
using namespace System.Runtime.InteropServices
using namespace System.Management.Automation.Language
using namespace System.Security.Cryptography.X509Certificates

#Requires -RunAsAdministrator
#Requires -Modules cliHelper.core
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
enum InstallScope {
  LocalMachine # same as AllUsers
  CurrentUser
}
enum MdtAttribute {
  ManifestKey
  FileContent
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
  ModuleManager([string]$RootPath) { [void][ModuleManager]::_Create($RootPath, $this) }
  # static [ModuleManager] Create() { return [ModuleManager]::_Create($null, $null) } # does not make sense
  static [ModuleManager] Create([string]$RootPath) { return [ModuleManager]::_Create($RootPath, $null) }

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
          Split-Path -Path ([System.Management.Automation.Platform]::SelectProductNameForDirectory('USER_MODULES')) -Parent
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
  static [string] GetHostOs() {
    #TODO: refactor so that it returns one of these: [Enum]::GetNames([System.PlatformID])
    return $(switch ($true) {
        $([RuntimeInformation]::IsOSPlatform([OSPlatform]::Windows)) { "Windows"; break }
        $([RuntimeInformation]::IsOSPlatform([OSPlatform]::FreeBSD)) { "FreeBSD"; break }
        $([RuntimeInformation]::IsOSPlatform([OSPlatform]::Linux)) { "Linux"; break }
        $([RuntimeInformation]::IsOSPlatform([OSPlatform]::OSX)) { "MacOSX"; break }
        Default {
          "UNKNOWN"
        }
      }
    )
  }
  static [string] GetAuthorName() {
    trap {
      $os = [ModuleManager]::GetHostOs()
      $an = switch ($true) {
        $($os -eq "Windows") {
          Get-CimInstance -ClassName Win32_UserAccount -Verbose:$false | Where-Object { [Environment]::UserName -eq $_.Name } | Select-Object -ExpandProperty FullName
          break
        }
        $($os -in ("MacOSX", "Linux")) {
          $s = getent passwd "$([Environment]::UserName)"
          $s.Split(":")[4]
          break
        }
        Default {
          Write-Warning -Message "$([Environment]::OSVersion.Platform) OS is Not supported!"
        }
      }
    }
    $an = ''; if ($null -ne (Get-Command git -CommandType Application -ea Ignore)) {
      $an = git config --get user.name;
    }
    if ([string]::IsNullOrWhiteSpace($an)) {
      $an = [Environment]::GetEnvironmentVariable('USER')
    }
    return $an
  }
  static [string] GetAuthorEmail() {
    trap {
      Write-Warning "Running {$c} is not possible, so I assume your email is `"`$([Environment]::UserName)@gmail.com`""
      $ae = "$([Environment]::UserName)@gmail.com"
    }
    $ae = ""; $c = { git config --get user.email }
    if ($null -ne (Get-Command git -CommandType Application -ea Ignore)) {
      $ae = $c.Invoke()
    }
    return $ae
  }
  static [string] GetRelativePath([string]$RelativeTo, [string]$Path) {
    # $RelativeTo : The source path the result should be relative to. This path is always considered to be a directory.
    # $Path : The destination path.
    $result = [string]::Empty
    $Drive = $Path -replace "^([^\\/]+:[\\/])?.*", '$1'
    if ($Drive -ne ($RelativeTo -replace "^([^\\/]+:[\\/])?.*", '$1')) {
      Write-Verbose "Paths on different drives"
      return $Path # no commonality, different drive letters on windows
    }
    $RelativeTo = $RelativeTo -replace "^[^\\/]+:[\\/]", [IO.Path]::DirectorySeparatorChar
    $Path = $Path -replace "^[^\\/]+:[\\/]", [IO.Path]::DirectorySeparatorChar
    $RelativeTo = [IO.Path]::GetFullPath($RelativeTo).TrimEnd('\/') -replace "^[^\\/]+:[\\/]", [IO.Path]::DirectorySeparatorChar
    $Path = [IO.Path]::GetFullPath($Path) -replace "^[^\\/]+:[\\/]", [IO.Path]::DirectorySeparatorChar

    $commonLength = 0
    while ($Path[$commonLength] -eq $RelativeTo[$commonLength]) {
      $commonLength++
    }
    if ($commonLength -eq $RelativeTo.Length -and $RelativeTo.Length -eq $Path.Length) {
      Write-Verbose "Equal Paths"
      return "." # The same paths
    }
    if ($commonLength -eq 0) {
      Write-Verbose "Paths on different drives?"
      return $Drive + $Path # no commonality, different drive letters on windows
    }

    Write-Verbose "Common base: $commonLength $($RelativeTo.Substring(0,$commonLength))"
    # In case we matched PART of a name, like C:/Users/Joel and C:/Users/Joe
    while ($commonLength -gt $RelativeTo.Length -and ($RelativeTo[$commonLength] -ne [IO.Path]::DirectorySeparatorChar)) {
      $commonLength--
    }

    Write-Verbose "Common base: $commonLength $($RelativeTo.Substring(0,$commonLength))"
    # create '..' segments for segments past the common on the "$RelativeTo" path
    if ($commonLength -lt $RelativeTo.Length) {
      $result = @('..') * @($RelativeTo.Substring($commonLength).Split([IO.Path]::DirectorySeparatorChar).Where{ $_ }).Length -join ([IO.Path]::DirectorySeparatorChar)
    }
    return (@($result, $Path.Substring($commonLength).TrimStart([IO.Path]::DirectorySeparatorChar)).Where{ $_ } -join ([IO.Path]::DirectorySeparatorChar))
  }
  static [string] GetResolvedPath([string]$Path) {
    return [ModuleManager]::GetResolvedPath($((Get-Variable ExecutionContext).Value.SessionState), $Path)
  }
  static [string] GetResolvedPath([System.Management.Automation.SessionState]$session, [string]$Path) {
    $paths = $session.Path.GetResolvedPSPathFromPSPath($Path);
    if ($paths.Count -gt 1) {
      throw [IOException]::new([string]::Format([cultureinfo]::InvariantCulture, "Path {0} is ambiguous", $Path))
    } elseif ($paths.Count -lt 1) {
      throw [IOException]::new([string]::Format([cultureinfo]::InvariantCulture, "Path {0} not Found", $Path))
    }
    return $paths[0].Path
  }
  static [string] GetUnResolvedPath([string]$Path) {
    return [ModuleManager]::GetUnResolvedPath($((Get-Variable ExecutionContext).Value.SessionState), $Path)
  }
  static [string] GetUnResolvedPath([System.Management.Automation.SessionState]$session, [string]$Path) {
    return $session.Path.GetUnresolvedProviderPathFromPSPath($Path)
  }
  static hidden [ModuleManager] _Create([string]$RootPath, [ref]$o) {
    $b = [ModuleManager]::new();
    [Net.ServicePointManager]::SecurityProtocol = [ModuleManager]::GetSecurityProtocol();
    [Environment]::SetEnvironmentVariable('IsAC', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('IsCI', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('TF_BUILD'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('RUN_ID', $(if ([bool][int]$env:IsAC -or $env:CI -eq "true") { [Environment]::GetEnvironmentVariable('GITHUB_RUN_ID') }else { [Guid]::NewGuid().Guid.substring(0, 21).replace('-', [string]::Join('', (0..9 | Get-Random -Count 1))) + '_' }), [System.EnvironmentVariableTarget]::Process);
    [ModuleManager]::Useverbose = (Get-Variable VerbosePreference -ValueOnly -Scope global) -eq "continue"
    $_RootPath = [ModuleManager]::GetUnresolvedPath($RootPath);
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
  static [LocalPsModule] FindLocalPsModule([string]$Name) {
    if ($Name.Contains([string][Path]::DirectorySeparatorChar)) {
      $rName = [ModuleManager]::GetResolvedPath($Name)
      $bName = [Path]::GetDirectoryName($rName)
      if ([IO.Directory]::Exists($rName)) {
        return [ModuleManager]::FindLocalPsModule($bName, [IO.Directory]::GetParent($rName))
      }
    }
    return [ModuleManager]::FindLocalPsModule($Name, "", $null)
  }
  static [LocalPsModule] FindLocalPsModule([string]$Name, [string]$scope) {
    return [ModuleManager]::FindLocalPsModule($Name, $scope, $null)
  }
  static [LocalPsModule] FindLocalPsModule([string]$Name, [version]$version) {
    return [ModuleManager]::FindLocalPsModule($Name, "", $version)
  }
  static [LocalPsModule] FindLocalPsModule([string]$Name, [IO.DirectoryInfo]$ModuleBase) {
    [ValidateNotNullOrWhiteSpace()][string]$Name = $Name
    [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$ModuleBase = $ModuleBase
    $result = [LocalPsModule]::new(); $result.Scope = 'LocalMachine'
    $ModulePsd1 = ($ModuleBase.GetFiles().Where({ $_.Name -like "$Name*" -and $_.Extension -eq '.psd1' }))[0]
    if ($null -eq $ModulePsd1) { return $result }
    $result.Info = Read-ModuleData -File $ModulePsd1.FullName
    $result.Name = $ModulePsd1.BaseName
    $result.Psd1 = $ModulePsd1
    $result.Path = if ($result.Psd1.Directory.Name -as [version] -is [version]) { $result.Psd1.Directory.Parent } else { $result.Psd1.Directory }
    $result.Exists = $ModulePsd1.Exists
    $result.Version = $result.Info.ModuleVersion -as [version]
    $result.IsReadOnly = $ModulePsd1.IsReadOnly
    return $result
  }
  static [LocalPsModule] FindLocalPsModule([string]$Name, [string]$scope, [version]$version) {
    $Module = $null; [ValidateNotNullOrWhiteSpace()][string]$Name = $Name
    $PsModule_Paths = $([ModuleManager]::GetModulePaths($(if ([string]::IsNullOrWhiteSpace($scope)) { "LocalMachine" }else { $scope })).ForEach({ [IO.DirectoryInfo]::New("$_") }).Where({ $_.Exists })).GetDirectories().Where({ $_.Name -eq $Name });
    if ($PsModule_Paths.count -gt 0) {
      $Get_versionDir = [scriptblock]::Create('param([IO.DirectoryInfo[]]$direcrory) return ($direcrory | ForEach-Object { $_.GetDirectories() | Where-Object { $_.Name -as [version] -is [version] } })')
      $has_versionDir = $Get_versionDir.Invoke($PsModule_Paths).count -gt 0
      $ModulePsdFiles = $PsModule_Paths.ForEach({
          if ($has_versionDir) {
            [string]$MaxVersion = ($Get_versionDir.Invoke([IO.DirectoryInfo]::New("$_")) | Select-Object @{l = 'version'; e = { $_.BaseName -as [version] } } | Measure-Object -Property version -Maximum).Maximum
            [IO.FileInfo]::New([IO.Path]::Combine("$_", $MaxVersion, $_.BaseName + '.psd1'))
          } else {
            [IO.FileInfo]::New([IO.Path]::Combine("$_", $_.BaseName + '.psd1'))
          }
        }
      ).Where({ $_.Exists })
      $Req_ModulePsd1 = $(if ($null -eq $version) {
          $ModulePsdFiles | Sort-Object -Property version -Descending | Select-Object -First 1
        } else {
          $ModulePsdFiles | Where-Object { $(Read-ModuleData -File $_.FullName -Property ModuleVersion) -eq $version }
        }
      )
      $Module = [ModuleManager]::FindLocalPsModule($Req_ModulePsd1.Name, $Req_ModulePsd1.Directory)
    }
    return $Module
  }
  static [string[]] GetModulePaths() {
    return [ModuleManager]::GetModulePaths($null)
  }
  static [string[]] GetModulePaths([string]$scope) {
    [string[]]$_Module_Paths = [Environment]::GetEnvironmentVariable('PSModulePath').Split([IO.Path]::PathSeparator)
    if ([string]::IsNullOrWhiteSpace($scope)) { return $_Module_Paths }; [InstallScope]$scope = $scope
    if (!(Get-Variable -Name IsWindows -ErrorAction Ignore) -or $(Get-Variable IsWindows -ValueOnly)) {
      $psv = Get-Variable PSVersionTable -ValueOnly
      $allUsers_path = Join-Path -Path $env:ProgramFiles -ChildPath $(if ($psv.ContainsKey('PSEdition') -and $psv.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' })
      if ("$Scope" -eq 'CurrentUser') { $_Module_Paths = $_Module_Paths.Where({ $_ -notlike "*$($allUsers_path | Split-Path)*" -and $_ -notlike "*$env:SystemRoot*" }) }
    } else {
      $allUsers_path = Split-Path -Path ([Platform]::SelectProductNameForDirectory('SHARED_MODULES')) -Parent
      if ("$Scope" -eq 'CurrentUser') { $_Module_Paths = $_Module_Paths.Where({ $_ -notlike "*$($allUsers_path | Split-Path)*" -and $_ -notlike "*/var/lib/*" }) }
    }
    return $_Module_Paths
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

class ModuleFile {
  [ValidateNotNullOrEmpty()][string]$Name
  [ValidateNotNullOrEmpty()][FileInfo]$value
  ModuleFile([string]$Name, [string]$value) {
    $this.Name = $Name; $this.value = [FileInfo]::new($value)
  }
  ModuleFile([string]$Name, [FileInfo]$value) {
    $this.Name = $Name
    $this.value = $value
  }
}
class ModuleFolder {
  [ValidateNotNullOrEmpty()][string]$Name
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$value
  ModuleFolder([string]$Name, [string]$value) {
    $this.Name = $Name; $this.value = [IO.DirectoryInfo]::new($value)
  }
  ModuleFolder([string]$Name, [IO.DirectoryInfo]$value) {
    $this.Name = $Name
    $this.value = $value
  }
}

class LocalPsModule {
  [ValidateNotNullOrEmpty()][FileInfo]$Psd1
  [ValidateNotNullOrEmpty()][version]$version
  [ValidateNotNullOrWhiteSpace()][string]$Name
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$Path
  [bool]$HasVersiondirs = $false
  [bool]$IsReadOnly = $false
  [PsObject]$Info = $null
  [bool]$Exists = $false
  [InstallScope]$Scope

  LocalPsModule() {}
  LocalPsModule([string]$Name) {
    [void][LocalPsModule]::_Create($Name, $null, $null, [ref]$this)
  }
  LocalPsModule([string]$Name, [string]$scope) {
    [void][LocalPsModule]::_Create($Name, $scope, $null, [ref]$this)
  }
  LocalPsModule([string]$Name, [version]$version) {
    [void][LocalPsModule]::_Create($Name, $null, $version, [ref]$this)
  }
  LocalPsModule([string]$Name, [string]$scope, [version]$version) {
    [void][LocalPsModule]::_Create($Name, $scope, $version, [ref]$this)
  }
  static [LocalPsModule] Create() { return [LocalPsModule]::new() }
  static [LocalPsModule] Create([string]$Name) {
    $o = [LocalPsModule]::new(); return [LocalPsModule]::_Create($Name, $null, $null, [ref]$o)
  }
  static [LocalPsModule] Create([string]$Name, [string]$scope) {
    $o = [LocalPsModule]::new(); return [LocalPsModule]::_Create($Name, $scope, $null, [ref]$o)
  }
  static [LocalPsModule] Create([string]$Name, [version]$version) {
    $o = [LocalPsModule]::new(); return [LocalPsModule]::_Create($Name, $null, $version, [ref]$o)
  }
  static [LocalPsModule] Create([string]$Name, [string]$scope, [version]$version) {
    $o = [LocalPsModule]::new(); return [LocalPsModule]::_Create($Name, $scope, $version, [ref]$o)
  }
  static hidden [LocalPsModule] _Create([string]$Name, [string]$scope, [version]$version, [ref]$o) {
    if ($null -eq $o) { throw "reference is null" };
    $m = [ModuleManager]::FindLocalPsModule($Name, $scope, $version);
    if ($null -eq $m) { $m = [LocalPsModule]::new() }
    $o.value.GetType().GetProperties().ForEach({
        $v = $m.$($_.Name)
        if ($null -ne $v) {
          $o.value.$($_.Name) = $v
        }
      }
    )
    return $o.Value
  }
  [void] Delete() {
    Remove-Item $this.Path -Recurse -Force -ErrorAction Ignore
  }
}

class PsModuleData {
  static hidden [string] $LICENSE_TXT
  static hidden [string[]] $configuration_values = $(Get-Module PsCraft -Verbose:$false).PsObject.Properties.Name + 'ModuleVersion'
  [ValidateNotNullOrWhiteSpace()][String] $Key
  [ValidateNotNullOrEmpty()][Type] $Type
  [MdtAttribute[]] $Attributes = @()
  hidden $Value

  PsModuleData([array]$k_v_t) {
    if ($k_v_t.Count -eq 3) {
      [void][PsModuleData]::_create([string]$k_v_t[0], $k_v_t[1], [Type]$k_v_t[2], [ref]$this)
    } elseif ($k_v_t.Count -eq 2) {
      [void][PsModuleData]::_Create([string]$k_v_t[0], $k_v_t[1], [ref]$this)
    } else {
      throw [System.TypeInitializationException]::new("PsModuleData", [System.ArgumentException]::new("[PsModuleData]::new([array]`$k_v_t) failed. k_v_t.count should be 3 or 2.", "key_value_type array"))
    }
  }
  PsModuleData([String]$Key, $Value) {
    [void][PsModuleData]::_create($Key, $Value, $Value.GetType(), @(), [ref]$this)
  }
  PsModuleData([String]$Key, $Value, [Type]$Type) {
    [void][PsModuleData]::_create($Key, $Value, $Type, @(), [ref]$this)
  }
  PsModuleData([String]$Key, $Value, [ModuleFile[]]$files) {
    [void][PsModuleData]::_create($Key, $Value, $Value.GetType(), $files, [ref]$this)
  }
  static [Collection[PsModuleData]] Create([hashtable]$hashtable, [ModuleFile[]]$Files) {
    $mdta = [Collection[PsModuleData]]::new()
    $arry = @(); $hashtable.Keys.ForEach({ $arry += [PsModuleData]::new($_, $hashtable[$_], $Files) })
    $arry.ForEach({ [void]$mdta.Add($_) })
    return $mdta
  }
  static [Collection[PsModuleData]] Create([string]$Name, [string]$Path, [List[ModuleFile]]$Files) {
    $AuthorName = [ModuleManager]::GetAuthorName(); $AuthorEmail = [ModuleManager]::GetAuthorEmail()
    $props = @{
      Path                  = [Path]::Combine($Path, $Path.Split([Path]::DirectorySeparatorChar)[-1] + ".psd1")
      Guid                  = [guid]::NewGuid()
      Year                  = [datetime]::Now.Year
      Author                = $AuthorName
      UserName              = $AuthorEmail.Split('@')[0]
      Copyright             = $("Copyright {0} {1} {2}. All rights reserved." -f [string][char]169, [datetime]::Now.Year, $AuthorName);
      RootModule            = $Name + '.psm1'
      ClrVersion            = [string]::Join('.', (Get-Variable 'PSVersionTable' -ValueOnly).SerializationVersion.ToString().split('.')[0..2])
      ModuleName            = $Name
      Description           = "A longer description of the Module, its purpose, common use cases, etc."
      CompanyName           = $AuthorEmail.Split('@')[0]
      AuthorEmail           = $AuthorEmail
      ModuleVersion         = [version]::new(0, 1, 0)
      RequiredModules       = @(
        "PSScriptAnalyzer"
      )
      PowerShellVersion     = [version][string]::Join('', (Get-Variable 'PSVersionTable').Value.PSVersion.Major.ToString(), '.0')
      Readme                = [PsModule]::GetModuleReadmeText()
      License               = [PsModuleData]::LICENSE_TXT ? [PsModuleData]::LICENSE_TXT : [PsModule]::GetModuleLicenseText()
      Builder               = {
        #!/usr/bin/env pwsh
        # .SYNOPSIS
        #   <ModuleName> buildScript v<ModuleVersion>
        # .DESCRIPTION
        #   A custom build script for the module <ModuleName>
        # .LINK
        #   https://github.com/<UserName>/<ModuleName>/blob/main/build.ps1
        # .EXAMPLE
        #   ./build.ps1 -Task Test
        #   This Will build the module, Import it and run tests using the ./Test-Module.ps1 script.
        #   ie: running ./build.ps1 only will "Compile & Import" the module; That's it, no tests.
        # .EXAMPLE
        #   ./build.ps1 -Task deploy
        #   Will build the module, test it and deploy it to PsGallery
        # .NOTES
        #   Author   : <Author>
        #   Copyright: <Copyright>
        #   License  : MIT
        [cmdletbinding(DefaultParameterSetName = 'task')]
        param(
          [parameter(Mandatory = $false, Position = 0, ParameterSetName = 'task')]
          [ValidateScript({
              $task_seq = [string[]]$_; $IsValid = $true
              $Tasks = @('Clean', 'Compile', 'Test', 'Deploy')
              foreach ($name in $task_seq) {
                $IsValid = $IsValid -and ($name -in $Tasks)
              }
              if ($IsValid) {
                return $true
              } else {
                throw [System.ArgumentException]::new('Task', "ValidSet: $($Tasks -join ', ').")
              }
            }
          )][ValidateNotNullOrEmpty()][Alias('t')]
          [string[]]$Task = 'Test',

          # Module buildRoot
          [Parameter(Mandatory = $false, Position = 1, ParameterSetName = 'task')]
          [ValidateScript({
              if (Test-Path -Path $_ -PathType Container -ea Ignore) {
                return $true
              } else {
                throw [System.ArgumentException]::new('Path', "Path: $_ is not a valid directory.")
              }
            })][Alias('p')]
          [string]$Path = (Resolve-Path .).Path,

          [Parameter(Mandatory = $false, ParameterSetName = 'task')]
          [string[]]$RequiredModules = @(),

          [parameter(ParameterSetName = 'task')]
          [Alias('i')]
          [switch]$Import,

          [parameter(ParameterSetName = 'help')]
          [Alias('h', '-help')]
          [switch]$Help
        )

        begin {
          if ($PSCmdlet.ParameterSetName -eq 'help') { Get-Help $MyInvocation.MyCommand.Source -Full | Out-String | Write-Host -f Green; return }
          $IsGithubRun = ![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))
          if ($($IsGithubRun ? $true : $(try { (Test-Connection "https://www.github.com" -Count 2 -TimeoutSeconds 1 -ea Ignore -Verbose:$false | Select-Object -expand Status) -contains "Success" } catch { Write-Warning "Test Connection Failed. $($_.Exception.Message)"; $false }))) {
            $req = Invoke-WebRequest -Method Get -Uri https://raw.githubusercontent.com/chadnpc/PsCraft/refs/heads/main/Public/Build-Module.ps1 -SkipHttpErrorCheck -Verbose:$false
            if ($req.StatusCode -ne 200) { throw "Failed to download Build-Module.ps1" }
            $t = New-Item $([IO.Path]::GetTempFileName().Replace('.tmp', '.ps1')) -Verbose:$false; Set-Content -Path $t.FullName -Value $req.Content; . $t.FullName; Remove-Item $t.FullName -Verbose:$false
          } else {
            $m = Get-InstalledModule PsCraft -Verbose:$false -ea Ignore
            $b = [IO.FileInfo][IO.Path]::Combine($m.InstalledLocation, 'Public', 'Build-Module.ps1')
            if ($b.Exists) { . $b.FullName }
          }
        }
        process {
          Build-Module -Task $Task -Path $Path -Import:$Import
        }
      }
      Tester                = {
        #!/usr/bin/env pwsh
        # .SYNOPSIS
        #   <ModuleName> testScript v<ModuleVersion>
        # .EXAMPLE
        #   ./Test-Module.ps1 -version <ModuleVersion>
        #   Will test the module in ./BuildOutput/<ModuleName>/<ModuleVersion>/
        # .EXAMPLE
        #   ./Test-Module.ps1
        #   Will test the latest  module version in ./BuildOutput/<ModuleName>/
        param (
          [Parameter(Mandatory = $false, Position = 0)]
          [Alias('Module')][string]$ModulePath = $PSScriptRoot,
          # Path Containing Tests
          [Parameter(Mandatory = $false, Position = 1)]
          [Alias('Tests')][string]$TestsPath = [IO.Path]::Combine($PSScriptRoot, 'Tests'),

          # Version string
          [Parameter(Mandatory = $false, Position = 2)]
          [ValidateScript({
              if (($_ -as 'version') -is [version]) {
                return $true
              } else {
                throw [System.IO.InvalidDataException]::New('Please Provide a valid version')
              }
            }
          )][ArgumentCompleter({
              [OutputType([System.Management.Automation.CompletionResult])]
              param([string]$CommandName, [string]$ParameterName, [string]$WordToComplete, [System.Management.Automation.Language.CommandAst]$CommandAst, [System.Collections.IDictionary]$FakeBoundParameters)
              $CompletionResults = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
              $b_Path = [IO.Path]::Combine($PSScriptRoot, 'BuildOutput', '<ModuleName>')
              if ((Test-Path -Path $b_Path -PathType Container -ErrorAction Ignore)) {
                [IO.DirectoryInfo]::New($b_Path).GetDirectories().Name | Where-Object { $_ -like "*$wordToComplete*" -and $_ -as 'version' -is 'version' } | ForEach-Object { [void]$CompletionResults.Add([System.Management.Automation.CompletionResult]::new($_, $_, "ParameterValue", $_)) }
              }
              return $CompletionResults
            }
          )]
          [string]$version,
          [switch]$skipBuildOutputTest,
          [switch]$CleanUp
        )
        begin {
          $TestResults = $null
          $BuildOutput = [IO.DirectoryInfo]::New([IO.Path]::Combine($PSScriptRoot, 'BuildOutput', '<ModuleName>'))
          if (!$BuildOutput.Exists) {
            Write-Warning "NO_Build_OutPut | Please make sure to Build the module successfully before running tests..";
            throw [System.IO.DirectoryNotFoundException]::new("Cannot find path '$($BuildOutput.FullName)' because it does not exist.")
          }
          # Get latest built version
          if ([string]::IsNullOrWhiteSpace($version)) {
            $version = $BuildOutput.GetDirectories().Name -as 'version[]' | Select-Object -Last 1
          }
          $BuildOutDir = Resolve-Path $([IO.Path]::Combine($PSScriptRoot, 'BuildOutput', '<ModuleName>', $version)) -ErrorAction Ignore | Get-Item -ErrorAction Ignore
          if (!$BuildOutDir.Exists) { throw [System.IO.DirectoryNotFoundException]::new($BuildOutDir) }
          $manifestFile = [IO.FileInfo]::New([IO.Path]::Combine($BuildOutDir.FullName, "<ModuleName>.psd1"))
          Write-Host "[+] Checking Prerequisites ..." -ForegroundColor Green
          if (!$BuildOutDir.Exists) {
            $msg = 'Directory "{0}" Not Found. First make sure you successfuly built the module.' -f ([IO.Path]::GetRelativePath($PSScriptRoot, $BuildOutDir.FullName))
            if ($skipBuildOutputTest.IsPresent) {
              Write-Warning "$msg"
            } else {
              throw [System.IO.DirectoryNotFoundException]::New($msg)
            }
          }
          if (!$skipBuildOutputTest.IsPresent -and !$manifestFile.Exists) {
            throw [System.IO.FileNotFoundException]::New("Could Not Find Module manifest File $([IO.Path]::GetRelativePath($PSScriptRoot, $manifestFile.FullName))")
          }
          if (!(Test-Path -Path $([IO.Path]::Combine($PSScriptRoot, "<ModuleName>.psd1")) -PathType Leaf -ErrorAction Ignore)) { throw [System.IO.FileNotFoundException]::New("Module manifest file Was not Found in '$($BuildOutDir.FullName)'.") }
          $script:fnNames = [System.Collections.Generic.List[string]]::New(); $testFiles = [System.Collections.Generic.List[IO.FileInfo]]::New()
          [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', '<ModuleName>.Integration.Tests.ps1')))
          [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', '<ModuleName>.Features.Tests.ps1')))
          [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', '<ModuleName>.Module.Tests.ps1')))
        }

        process {
          Get-Module PsCraft | Remove-Module -Force -Verbose:$false
          Write-Host "[+] Checking test files ..." -ForegroundColor Green
          $missingTestFiles = $testFiles.Where({ !$_.Exists })
          if ($missingTestFiles.count -gt 0) { throw [System.IO.FileNotFoundException]::new($($testFiles.BaseName -join ', ')) }
          Write-Host "[+] Testing ModuleManifest ..." -ForegroundColor Green
          if (!$skipBuildOutputTest.IsPresent) {
            Test-ModuleManifest -Path $manifestFile.FullName -ErrorAction Stop -Verbose
          }
          $PesterConfig = New-PesterConfiguration
          $PesterConfig.TestResult.OutputFormat = "NUnitXml"
          $PesterConfig.TestResult.OutputPath = [IO.Path]::Combine("$TestsPath", "results.xml")
          $PesterConfig.TestResult.Enabled = $True
          $TestResults = Invoke-Pester -Configuration $PesterConfig
        }

        end {
          return $TestResults
        }
      }
      LocalData             = {
        @{
          ModuleName    = '<ModuleName>'
          ModuleVersion = [version]'<ModuleVersion>'
          ReleaseNotes  = '<ReleaseNotes>'
        }
      }
      LicenseUri            = "https://alain.MIT-license.org"
      ProjectUri            = "https://github.com/$AuthorName/$Name"
      IconUri               = 'https://github.com/user-attachments/assets/1220c30e-a309-43c3-9a80-1948dae30e09'
      rootLoader            = {
        #!/usr/bin/env pwsh
        #region    Classes
        #endregion Classes
        # Types that will be available to users when they import the module.
        $typestoExport = @()
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
      }
      ModuleTest            = {
        $script:ModuleName = (Get-Item "$PSScriptRoot/..").Name
        $script:ModulePath = Resolve-Path "$PSScriptRoot/../BuildOutput/$ModuleName" | Get-Item
        $script:moduleVersion = ((Get-ChildItem $ModulePath).Where({ $_.Name -as 'version' -is 'version' }).Name -as 'version[]' | Sort-Object -Descending)[0].ToString()

        Write-Host "[+] Testing the latest built module:" -ForegroundColor Green
        Write-Host "      ModuleName    $ModuleName"
        Write-Host "      ModulePath    $ModulePath"
        Write-Host "      Version       $moduleVersion`n"

        Get-Module -Name $ModuleName | Remove-Module # Make sure no versions of the module are loaded

        Write-Host "[+] Reading module information ..." -ForegroundColor Green
        $script:ModuleInformation = Import-Module -Name "$ModulePath" -PassThru
        $script:ModuleInformation | Format-List

        Write-Host "[+] Get all functions present in the Manifest ..." -ForegroundColor Green
        $script:ExportedFunctions = $ModuleInformation.ExportedFunctions.Values.Name
        Write-Host "      ExportedFunctions: " -ForegroundColor DarkGray -NoNewline
        Write-Host $($ExportedFunctions -join ', ')
        $script:PS1Functions = Get-ChildItem -Path "$ModulePath/$moduleVersion/Public/*.ps1" -Recurse

        Describe "Module tests for $($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')))" {
          Context " Confirm valid Manifest file" {
            It "Should contain RootModule" {
              ![string]::IsNullOrWhiteSpace($ModuleInformation.RootModule) | Should -Be $true
            }

            It "Should contain ModuleVersion" {
              ![string]::IsNullOrWhiteSpace($ModuleInformation.Version) | Should -Be $true
            }

            It "Should contain GUID" {
              ![string]::IsNullOrWhiteSpace($ModuleInformation.Guid) | Should -Be $true
            }

            It "Should contain Author" {
              ![string]::IsNullOrWhiteSpace($ModuleInformation.Author) | Should -Be $true
            }

            It "Should contain Description" {
              ![string]::IsNullOrWhiteSpace($ModuleInformation.Description) | Should -Be $true
            }
          }
          Context " Should export all public functions " {
            It "Compare the number of Function Exported and the PS1 files found in the public folder" {
              $status = $ExportedFunctions.Count -eq $PS1Functions.Count
              $status | Should -Be $true
            }

            It "The number of missing functions should be 0 " {
              If ($ExportedFunctions.count -ne $PS1Functions.count) {
                $Compare = Compare-Object -ReferenceObject $ExportedFunctions -DifferenceObject $PS1Functions.Basename
                $($Compare.InputObject -Join '').Trim() | Should -BeNullOrEmpty
              }
            }
          }
          Context " Confirm files are valid Powershell syntax " {
            $_scripts = $(Get-Item -Path "$ModulePath/$moduleVersion").GetFiles(
              "*", [System.IO.SearchOption]::AllDirectories
            ).Where({ $_.Extension -in ('.ps1', '.psd1', '.psm1') })
            $testCase = $_scripts | ForEach-Object { @{ file = $_ } }
            It "ie: each Script/Ps1file should have valid Powershell sysntax" -TestCases $testCase {
              param($file) $contents = Get-Content -Path $file.fullname -ErrorAction Stop
              $errors = $null; [void][System.Management.Automation.PSParser]::Tokenize($contents, [ref]$errors)
              $errors.Count | Should -Be 0
            }
          }
          Context " Confirm there are no duplicate function names in private and public folders" {
            It ' Should have no duplicate functions' {
              $Publc_Dir = Get-Item -Path ([IO.Path]::Combine("$ModulePath/$moduleVersion", 'Public'))
              $Privt_Dir = Get-Item -Path ([IO.Path]::Combine("$ModulePath/$moduleVersion", 'Private'))
              $funcNames = @(); Test-Path -Path ([string[]]($Publc_Dir, $Privt_Dir)) -PathType Container -ErrorAction Stop
              $Publc_Dir.GetFiles("*", [System.IO.SearchOption]::AllDirectories) + $Privt_Dir.GetFiles("*", [System.IO.SearchOption]::AllDirectories) | Where-Object { $_.Extension -eq '.ps1' } | ForEach-Object { $funcNames += $_.BaseName }
              $($funcNames | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -BeLessThan 1
            }
          }
        }
        Remove-Module -Name $ModuleName -Force
      }
      FeatureTest           = {
        Describe "Feature tests: <ModuleName>" {
          Context "Feature 1" {
            It "Does something expected" {
              # Write tests to verify the behavior of a specific feature.
              # For instance, if you have a feature to change the console background color,
              # you could simulate the invocation of the related function and check if the color changes as expected.
            }
          }
          Context "Feature 2" {
            It "Performs another expected action" {
              # Write tests for another feature.
            }
          }
          # TODO: Add more contexts and tests to cover various features and functionalities.
        }
      }
      IntegrationTest       = {
        # verify the interactions and behavior of the module's components when they are integrated together.
        Describe "Integration tests: <ModuleName>" {
          Context "Functionality Integration" {
            It "Performs expected action" {
              # Here you can write tests to simulate the usage of your functions and validate their behavior.
              # For instance, if your module provides cmdlets to customize the command-line environment,
              # you could simulate the invocation of those cmdlets and check if the environment is modified as expected.
            }
          }
          # TODO: Add more contexts and tests as needed to cover various integration scenarios.
        }
      }
      ScriptAnalyzer        = {
        @{
          IncludeDefaultRules = $true
          ExcludeRules        = @(
            'PSAvoidUsingWriteHost',
            'PSReviewUnusedParameter',
            'PSUseSingularNouns'
          )

          Rules               = @{
            PSPlaceOpenBrace           = @{
              Enable             = $true
              OnSameLine         = $true
              NewLineAfter       = $true
              IgnoreOneLineBlock = $true
            }

            PSPlaceCloseBrace          = @{
              Enable             = $true
              NewLineAfter       = $false
              IgnoreOneLineBlock = $true
              NoEmptyLineBefore  = $true
            }

            PSUseConsistentIndentation = @{
              Enable              = $true
              Kind                = 'space'
              PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
              IndentationSize     = 2
            }

            PSUseConsistentWhitespace  = @{
              Enable                                  = $true
              CheckInnerBrace                         = $true
              CheckOpenBrace                          = $true
              CheckOpenParen                          = $true
              CheckOperator                           = $false
              CheckPipe                               = $true
              CheckPipeForRedundantWhitespace         = $false
              CheckSeparator                          = $true
              CheckParameter                          = $false
              IgnoreAssignmentOperatorInsideHashTable = $true
            }

            PSAlignAssignmentStatement = @{
              Enable         = $true
              CheckHashtable = $true
            }

            PSUseCorrectCasing         = @{
              Enable = $true
            }
          }
        }
      }
      DelWorkflowsyaml      = [PsModule]::GetModuleDelWorkflowsyaml()
      Codereviewyaml        = [PsModule]::GetModuleCodereviewyaml()
      Publishyaml           = [PsModule]::GetModulePublishyaml()
      CICDyaml              = [PsModule]::GetModuleCICDyaml()
      Tags                  = [string[]]("PowerShell", [Environment]::UserName)
      ReleaseNotes          = "# Release Notes`n`n- Version_<ModuleVersion>`n- Functions ...`n- Optimizations`n"
      ProcessorArchitecture = 'None'
      #CompatiblePSEditions = $($Ps_Ed = (Get-Variable 'PSVersionTable').Value.PSEdition; if ([string]::IsNullOrWhiteSpace($Ps_Ed)) { 'Desktop' } else { $Ps_Ed }) # skiped on purpose. <<< https://blog.netnerds.net/2023/03/dont-waste-your-time-with-core-versions
    }
    $_PSVersion = $props["PowerShellVersion"]; [ValidateScript({ $_ -ge [version]"2.0" -and $_ -le [version]"7.0" })]$_PSVersion = $_PSVersion
    return [PsModuleData]::Create($props, $Files)
  }
  static hidden [PsModuleData] _create([String]$Key, $Value, [ref]$o) { return [PsModuleData]::_create($Key, $Value, $Value.GetType(), @(), [ref]$o) }
  static hidden [PsModuleData] _create([String]$Key, $Value, [Type]$Type, [ModuleFile[]]$Files, [ref]$o) {
    $o.Value.Key = $Key; $o.Value.Type = $Type; $o.Value.Value = $Value -as $Type
    if ($Files.Name.Contains($Key)) { $o.Value.Attributes += "FileContent" }
    # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/new-modulemanifest#example-5-getting-module-information
    if ($Key -in [PsModuleData]::configuration_values) { $o.Value.Attributes += "ManifestKey" }
    return $o.Value
  }
  static [Collection[PsModuleData]] ReplaceTemplates([Collection[PsModuleData]]$data) {
    $templates = $data.Where({ $_.Type.Name -in ("String", "ScriptBlock") })
    $hashtable = @{}; $data.Foreach({ $hashtable += @{ $_.Key = $_.Value } }); $keys = $hashtable.Keys
    foreach ($item in $templates) {
      [string]$n = $item.Key
      [string]$t = $item.Type.Name
      if ([string]::IsNullOrWhiteSpace($n)) { Write-Warning "`$item.Key is empty"; continue }
      if ([string]::IsNullOrWhiteSpace($t)) { Write-Warning "`$item.Type.Name is empty"; continue }
      switch ($t) {
        'ScriptBlock' {
          if ($null -eq $hashtable[$n]) { break }
          $str = $hashtable[$n].ToString()
          $keys.ForEach({
              if ($str -match "<$_>") {
                $str = $str.Replace("<$_>", $hashtable["$_"])
                $item.Set([scriptblock]::Create($str))
                Write-Debug "`$module.data.$($item.Key) Replaced <$_>)"
              }
            }
          )
          break
        }
        'String' {
          if ($null -eq $hashtable[$n]) { break }
          $str = $hashtable[$n]
          $keys.ForEach({
              if ($str -match "<$_>") {
                $str = $str.Replace("<$_>", $hashtable["$_"])
                $item.Set($str)
                Write-Debug "`$module.data.$($item.Key) Replaced <$_>"
              }
            }
          )
          break
        }
        Default {
          Write-Warning "Unknown Type: $t"
          continue
        }
      }
    }
    return $data
  }
  [void] Set($Value) { $this.Value = $Value }
  [void] Format() {
    if ($this.Type.Name -in ('String', 'ScriptBlock')) {
      try {
        # Write-Host "FORMATTING: << $($this.Key) : $($this.Type.Name)" -f Blue -NoNewline
        $this.Value = Invoke-Formatter -ScriptDefinition $this.Value.ToString() -Verbose:$false
      } catch {
        # Write-Host " Attempt to format the file line by line. " -f Magenta -nonewline
        $content = $this.Value.ToString()
        $formattedLines = @()
        foreach ($line in $content) {
          try {
            $formattedLine = Invoke-Formatter -ScriptDefinition $line -Verbose:$false
            $formattedLines += $formattedLine
          } catch {
            # If formatting fails, keep the original line
            $formattedLines += $line
          }
        }
        $_value = [string]::Join([Environment]::NewLine, $formattedLines)
        if ($this.Type.Name -eq 'String') {
          $this.Value = $_value
        } elseif ($this.Type.Name -eq 'ScriptBlock') {
          $this.Value = [scriptblock]::Create("$_value")
        }
      }
      # Write-Host " done $($this.Key) >>" -f Green
    }
  }
}

class PsModule {
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
    $b = [ModuleManager]::GetUnResolvedPath($Path); $p = [IO.Path]::Combine($b, $Name);
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
    $mroot = [Path]::Combine([ModuleManager]::GetUnResolvedPath($(
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
      DelWorkflowsyaml = [Path]::Combine($workflows, 'Delete_old_workflow_runs.yaml')
      Codereviewyaml   = [Path]::Combine($workflows, 'Codereview.yaml')
      Publishyaml      = [Path]::Combine($workflows, 'Publish.yaml')
      CICDyaml         = [Path]::Combine($workflows, 'CI.yaml')
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
  [void] Delete() {
    Get-Module $this.Name | Remove-Module -Force -ErrorAction SilentlyContinue
    Remove-Item $this.Path.FullName -Recurse -Force -ErrorAction SilentlyContinue
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
  static [string] GetModuleLicenseText() {
    if (![PsModuleData]::LICENSE_TXT) {
      trap {
        Write-Warning "Failed to decode license text, lets get it fom web"
        $url = 'http://sam.zoy.org/wtfpl/COPYING'
        $req = Invoke-WebRequest $url -Verbose:$false -SkipHttpErrorCheck -ea Ignore
        if ($req.StatusCode -eq 200) {
          $TXT = [string]$req.Content
          if (![string]::IsNullOrWhiteSpace($TXT)) {
            [PsModuleData]::LICENSE_TXT = $TXT.Replace('2004 Sam Hocevar <sam@hocevar.net>', "$([datetime]::Now.Year) $([ModuleManager]::GetAuthorName()) <$([ModuleManager]::GetAuthorEmail())>")
          } else {
            Write-Warning "Got empty LICENSE from $url"
          }
        } else {
          Write-Warning "Failed to fetch LICENSE"
        }
      }
      [PsModuleData]::LICENSE_TXT = [Encoding]::UTF8.GetString([Convert]::FromBase64String("ICAgICAgICAgICAgRE8gV0hBVCBUSEUgRlVDSyBZT1UgV0FOVCBUTyBQVUJMSUMgTElDRU5TRQ0KICAgICAgICAgICAgICAgICAgICBWZXJzaW9uIDIsIERlY2VtYmVyIDIwMDQNCg0KIDxDb3B5cmlnaHQ+DQoNCiBFdmVyeW9uZSBpcyBwZXJtaXR0ZWQgdG8gY29weSBhbmQgZGlzdHJpYnV0ZSB2ZXJiYXRpbSBvciBtb2RpZmllZA0KIGNvcGllcyBvZiB0aGlzIGxpY2Vuc2UgZG9jdW1lbnQsIGFuZCBjaGFuZ2luZyBpdCBpcyBhbGxvd2VkIGFzIGxvbmcNCiBhcyB0aGUgbmFtZSBpcyBjaGFuZ2VkLg0KDQogICAgICAgICAgICBETyBXSEFUIFRIRSBGVUNLIFlPVSBXQU5UIFRPIFBVQkxJQyBMSUNFTlNFDQogICBURVJNUyBBTkQgQ09ORElUSU9OUyBGT1IgQ09QWUlORywgRElTVFJJQlVUSU9OIEFORCBNT0RJRklDQVRJT04NCg0KICAwLiBZb3UganVzdCBETyBXSEFUIFRIRSBGVUNLIFlPVSBXQU5UIFRPLg0KDQo="));
    }
    return [PsModuleData]::LICENSE_TXT
  }
  static [string] GetModuleReadmeText() {
    return [Encoding]::UTF8.GetString([Convert]::FromBase64String("CiMgWzxNb2R1bGVOYW1lPl0oaHR0cHM6Ly93d3cucG93ZXJzaGVsbGdhbGxlcnkuY29tL3BhY2thZ2VzLzxNb2R1bGVOYW1lPikKCvCflKUgQmxhemluZ2x5IGZhc3QgUG93ZXJTaGVsbCB0aGluZ3kgdGhhdCBzdG9ua3MgdXAgeW91ciB0ZXJtaW5hbCBnYW1lLgoKIyMgVXNhZ2UKCmBgYFBvd2VyU2hlbGwKSW5zdGFsbC1Nb2R1bGUgPE1vZHVsZU5hbWU+CmBgYAoKdGhlbgoKYGBgUG93ZXJTaGVsbApJbXBvcnQtTW9kdWxlIDxNb2R1bGVOYW1lPgojIGRvIHN0dWZmIGhlcmUuCmBgYAoKIyMgTGljZW5zZQoKVGhpcyBwcm9qZWN0IGlzIGxpY2Vuc2VkIHVuZGVyIHRoZSBbV1RGUEwgTGljZW5zZV0oTElDRU5TRSku"));
  }
  static [string] GetModuleCICDyaml() {
    return [Encoding]::UTF8.GetString([Convert]::FromBase64String("bmFtZTogQ0kKb246IFtwdXNoLCBwdWxsX3JlcXVlc3QsIHdvcmtmbG93X2Rpc3BhdGNoXQpkZWZhdWx0czoKICBydW46CiAgICBzaGVsbDogcHdzaAoKam9iczoKICBidWlsZDoKICAgIG5hbWU6IFJ1bnMgb24gYWxsIHBsYXRmb3JtcwogICAgcnVucy1vbjogJHt7IG1hdHJpeC5vcyB9fQogICAgc3RyYXRlZ3k6CiAgICAgIGZhaWwtZmFzdDogZmFsc2UKICAgICAgbWF0cml4OgogICAgICAgIG9zOiBbdWJ1bnR1LWxhdGVzdCwgd2luZG93cy1sYXRlc3QsIG1hY09TLWxhdGVzdF0KICAgIHN0ZXBzOgogICAgICAtIHVzZXM6IGFjdGlvbnMvY2hlY2tvdXRAdjMKICAgICAgLSBuYW1lOiBCdWlsZAogICAgICAgIHJ1bjogLi9idWlsZC5wczEgLVRhc2sgVGVzdA=="));
  }
  static [string] GetModuleCodereviewyaml() {
    return [Encoding]::UTF8.GetString([Convert]::FromBase64String("bmFtZTogQ29kZSBSZXZpZXcKcGVybWlzc2lvbnM6CiAgY29udGVudHM6IHJlYWQKICBwdWxsLXJlcXVlc3RzOiB3cml0ZQoKb246CiAgcHVsbF9yZXF1ZXN0OgogICAgdHlwZXM6IFtvcGVuZWQsIHJlb3BlbmVkLCBzeW5jaHJvbml6ZV0KCmpvYnM6CiAgdGVzdDoKICAgIHJ1bnMtb246IHVidW50dS1sYXRlc3QKICAgIHN0ZXBzOgogICAgICAtIHVzZXM6IGFuYzk1L0NoYXRHUFQtQ29kZVJldmlld0B2MS4wLjEyCiAgICAgICAgZW52OgogICAgICAgICAgR0lUSFVCX1RPS0VOOiAke3sgc2VjcmV0cy5HSVRIVUJfVE9LRU4gfX0KICAgICAgICAgIE9QRU5BSV9BUElfS0VZOiAke3sgc2VjcmV0cy5PUEVOQUlfQVBJX0tFWSB9fQogICAgICAgICAgTEFOR1VBR0U6IEVuZ2xpc2gKICAgICAgICAgIE9QRU5BSV9BUElfRU5EUE9JTlQ6IGh0dHBzOi8vYXBpLm9wZW5haS5jb20vdjEKICAgICAgICAgIE1PREVMOiBncHQtNG8gIyBodHRwczovL3BsYXRmb3JtLm9wZW5haS5jb20vZG9jcy9tb2RlbHMKICAgICAgICAgIFBST01QVDogUGxlYXNlIGNoZWNrIGlmIHRoZXJlIGFyZSBhbnkgY29uZnVzaW9ucyBvciBpcnJlZ3VsYXJpdGllcyBpbiB0aGUgZm9sbG93aW5nIGNvZGUgZGlmZgogICAgICAgICAgdG9wX3A6IDEKICAgICAgICAgIHRlbXBlcmF0dXJlOiAxCiAgICAgICAgICBtYXhfdG9rZW5zOiAxMDAwMAogICAgICAgICAgTUFYX1BBVENIX0xFTkdUSDogMTAwMDAgIyBpZiB0aGUgcGF0Y2gvZGlmZiBsZW5ndGggaXMgbGFyZ2UgdGhhbiBNQVhfUEFUQ0hfTEVOR1RILCB3aWxsIGJlIGlnbm9yZWQgYW5kIHdvbid0IHJldmlldy4="));
  }
  static [string] GetModulePublishyaml() {
    return [Encoding]::UTF8.GetString([Convert]::FromBase64String("bmFtZTogR2l0SHViIHJlbGVhc2UgYW5kIFB1Ymxpc2gKb246IFt3b3JrZmxvd19kaXNwYXRjaF0KZGVmYXVsdHM6CiAgcnVuOgogICAgc2hlbGw6IHB3c2gKam9iczoKICB1cGxvYWQtcGVzdGVyLXJlc3VsdHM6CiAgICBuYW1lOiBSdW4gUGVzdGVyIGFuZCB1cGxvYWQgcmVzdWx0cwogICAgcnVucy1vbjogdWJ1bnR1LWxhdGVzdAogICAgc3RlcHM6CiAgICAgIC0gdXNlczogYWN0aW9ucy9jaGVja291dEB2MwogICAgICAtIG5hbWU6IFRlc3Qgd2l0aCBQZXN0ZXIKICAgICAgICBzaGVsbDogcHdzaAogICAgICAgIHJ1bjogLi9UZXN0LU1vZHVsZS5wczEKICAgICAgLSBuYW1lOiBVcGxvYWQgdGVzdCByZXN1bHRzCiAgICAgICAgdXNlczogYWN0aW9ucy91cGxvYWQtYXJ0aWZhY3RAdjMKICAgICAgICB3aXRoOgogICAgICAgICAgbmFtZTogdWJ1bnR1LVVuaXQtVGVzdHMKICAgICAgICAgIHBhdGg6IFVuaXQuVGVzdHMueG1sCiAgICBpZjogJHt7IGFsd2F5cygpIH19CiAgcHVibGlzaC10by1nYWxsZXJ5OgogICAgbmFtZTogUHVibGlzaCB0byBQb3dlclNoZWxsIEdhbGxlcnkKICAgIHJ1bnMtb246IHVidW50dS1sYXRlc3QKICAgIHN0ZXBzOgogICAgICAtIHVzZXM6IGFjdGlvbnMvY2hlY2tvdXRAdjMKICAgICAgLSBuYW1lOiBQdWJsaXNoCiAgICAgICAgZW52OgogICAgICAgICAgR2l0SHViUEFUOiAke3sgc2VjcmV0cy5HaXRIdWJQQVQgfX0KICAgICAgICAgIE5VR0VUQVBJS0VZOiAke3sgc2VjcmV0cy5OVUdFVEFQSUtFWSB9fQogICAgICAgIHJ1bjogLi9idWlsZC5wczEgLVRhc2sgRGVwbG95"));
  }
  static [string] GetModuleDelWorkflowsyaml() {
    # The b64str length is getting out of hand!!
    # TODO" Use compressed base85 (https://github.com/chadnpc/Encodkit) instead of base64
    return [Encoding]::UTF8.GetString([Convert]::FromBase64String("bmFtZTogRGVsZXRlIG9sZCB3b3JrZmxvdyBydW5zCm9uOgogIHdvcmtmbG93X2Rpc3BhdGNoOgogICAgaW5wdXRzOgogICAgICBkYXlzOgogICAgICAgIGRlc2NyaXB0aW9uOiAnRGF5cy13b3J0aCBvZiBydW5zIHRvIGtlZXAgZm9yIGVhY2ggd29ya2Zsb3cnCiAgICAgICAgcmVxdWlyZWQ6IHRydWUKICAgICAgICBkZWZhdWx0OiAnMCcKICAgICAgbWluaW11bV9ydW5zOgogICAgICAgIGRlc2NyaXB0aW9uOiAnTWluaW11bSBydW5zIHRvIGtlZXAgZm9yIGVhY2ggd29ya2Zsb3cnCiAgICAgICAgcmVxdWlyZWQ6IHRydWUKICAgICAgICBkZWZhdWx0OiAnMScKICAgICAgZGVsZXRlX3dvcmtmbG93X3BhdHRlcm46CiAgICAgICAgZGVzY3JpcHRpb246ICdOYW1lIG9yIGZpbGVuYW1lIG9mIHRoZSB3b3JrZmxvdyAoaWYgbm90IHNldCwgYWxsIHdvcmtmbG93cyBhcmUgdGFyZ2V0ZWQpJwogICAgICAgIHJlcXVpcmVkOiBmYWxzZQogICAgICBkZWxldGVfd29ya2Zsb3dfYnlfc3RhdGVfcGF0dGVybjoKICAgICAgICBkZXNjcmlwdGlvbjogJ0ZpbHRlciB3b3JrZmxvd3MgYnkgc3RhdGU6IGFjdGl2ZSwgZGVsZXRlZCwgZGlzYWJsZWRfZm9yaywgZGlzYWJsZWRfaW5hY3Rpdml0eSwgZGlzYWJsZWRfbWFudWFsbHknCiAgICAgICAgcmVxdWlyZWQ6IHRydWUKICAgICAgICBkZWZhdWx0OiAiQUxMIgogICAgICAgIHR5cGU6IGNob2ljZQogICAgICAgIG9wdGlvbnM6CiAgICAgICAgICAtICJBTEwiCiAgICAgICAgICAtIGFjdGl2ZQogICAgICAgICAgLSBkZWxldGVkCiAgICAgICAgICAtIGRpc2FibGVkX2luYWN0aXZpdHkKICAgICAgICAgIC0gZGlzYWJsZWRfbWFudWFsbHkKICAgICAgZGVsZXRlX3J1bl9ieV9jb25jbHVzaW9uX3BhdHRlcm46CiAgICAgICAgZGVzY3JpcHRpb246ICdSZW1vdmUgcnVucyBiYXNlZCBvbiBjb25jbHVzaW9uOiBhY3Rpb25fcmVxdWlyZWQsIGNhbmNlbGxlZCwgZmFpbHVyZSwgc2tpcHBlZCwgc3VjY2VzcycKICAgICAgICByZXF1aXJlZDogdHJ1ZQogICAgICAgIGRlZmF1bHQ6ICJBTEwiCiAgICAgICAgdHlwZTogY2hvaWNlCiAgICAgICAgb3B0aW9uczoKICAgICAgICAgIC0gIkFMTCIKICAgICAgICAgIC0gIlVuc3VjY2Vzc2Z1bDogYWN0aW9uX3JlcXVpcmVkLGNhbmNlbGxlZCxmYWlsdXJlLHNraXBwZWQiCiAgICAgICAgICAtIGFjdGlvbl9yZXF1aXJlZAogICAgICAgICAgLSBjYW5jZWxsZWQKICAgICAgICAgIC0gZmFpbHVyZQogICAgICAgICAgLSBza2lwcGVkCiAgICAgICAgICAtIHN1Y2Nlc3MKICAgICAgZHJ5X3J1bjoKICAgICAgICBkZXNjcmlwdGlvbjogJ0xvZ3Mgc2ltdWxhdGVkIGNoYW5nZXMsIG5vIGRlbGV0aW9ucyBhcmUgcGVyZm9ybWVkJwogICAgICAgIHJlcXVpcmVkOiBmYWxzZQoKam9iczoKICBkZWxfcnVuczoKICAgIHJ1bnMtb246IHVidW50dS1sYXRlc3QKICAgIHBlcm1pc3Npb25zOgogICAgICBhY3Rpb25zOiB3cml0ZQogICAgICBjb250ZW50czogcmVhZAogICAgc3RlcHM6CiAgICAgIC0gbmFtZTogRGVsZXRlIHdvcmtmbG93IHJ1bnMKICAgICAgICB1c2VzOiBNYXR0cmFrcy9kZWxldGUtd29ya2Zsb3ctcnVuc0B2MgogICAgICAgIHdpdGg6CiAgICAgICAgICB0b2tlbjogJHt7IGdpdGh1Yi50b2tlbiB9fQogICAgICAgICAgcmVwb3NpdG9yeTogJHt7IGdpdGh1Yi5yZXBvc2l0b3J5IH19CiAgICAgICAgICByZXRhaW5fZGF5czogJHt7IGdpdGh1Yi5ldmVudC5pbnB1dHMuZGF5cyB9fQogICAgICAgICAga2VlcF9taW5pbXVtX3J1bnM6ICR7eyBnaXRodWIuZXZlbnQuaW5wdXRzLm1pbmltdW1fcnVucyB9fQogICAgICAgICAgZGVsZXRlX3dvcmtmbG93X3BhdHRlcm46ICR7eyBnaXRodWIuZXZlbnQuaW5wdXRzLmRlbGV0ZV93b3JrZmxvd19wYXR0ZXJuIH19CiAgICAgICAgICBkZWxldGVfd29ya2Zsb3dfYnlfc3RhdGVfcGF0dGVybjogJHt7IGdpdGh1Yi5ldmVudC5pbnB1dHMuZGVsZXRlX3dvcmtmbG93X2J5X3N0YXRlX3BhdHRlcm4gfX0KICAgICAgICAgIGRlbGV0ZV9ydW5fYnlfY29uY2x1c2lvbl9wYXR0ZXJuOiA+LQogICAgICAgICAgICAke3sKICAgICAgICAgICAgICBzdGFydHNXaXRoKGdpdGh1Yi5ldmVudC5pbnB1dHMuZGVsZXRlX3J1bl9ieV9jb25jbHVzaW9uX3BhdHRlcm4sICdVbnN1Y2Nlc3NmdWw6JykKICAgICAgICAgICAgICAmJiAnYWN0aW9uX3JlcXVpcmVkLGNhbmNlbGxlZCxmYWlsdXJlLHNraXBwZWQnCiAgICAgICAgICAgICAgfHwgZ2l0aHViLmV2ZW50LmlucHV0cy5kZWxldGVfcnVuX2J5X2NvbmNsdXNpb25fcGF0dGVybgogICAgICAgICAgICB9fQogICAgICAgICAgZHJ5X3J1bjogJHt7IGdpdGh1Yi5ldmVudC5pbnB1dHMuZHJ5X3J1biB9fQ=="));
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

class CodeSigner {
  CodeSigner() {}

  static [void] AddSignature([string]$File) {
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
    [CodeSigner]::SetAuthenticodeSignature($File, $cert)
  }

  static [void] SetAuthenticodeSignature($FilePath, $Certificate) {
    $params = @{
      FilePath        = $FilePath
      Certificate     = $Certificate
      TimestampServer = "http://timestamp.digicert.com"
    }
    $result = Set-AuthenticodeSignature @params
    if ($result.Status -ne "Valid") {
      throw "Failed to sign $FilePath. Status: $($result.Status)"
    }
  }

  # .SYNOPSIS
  # Export your signing key and certificate to a .pfx file
  # .DESCRIPTION
  # If you have a private key and certificate on your computer,
  # malicious programs might be able to sign scripts on your behalf, which authorizes PowerShell to run them.
  # To prevent automated signing on your behalf, use
  # [CodeSigner]::ExportCertificate to export your signing key and certificate to a .pfx file.
  static [string] ExportCertificate([string]$CertPath, [string]$ExportPath, [SecureString]$Password) {
    $cert = Get-ChildItem -Path $CertPath
    Export-PfxCertificate -Cert $cert -FilePath $ExportPath -Password $Password
    return $ExportPath
  }

  static [void] ImportCertificate([string]$PfxPath, [SecureString]$Password) {
    Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation Cert:\CurrentUser\My -Password $Password
  }

  static [bool] VerifySignature([string]$FilePath) {
    $signature = Get-AuthenticodeSignature -FilePath $FilePath
    return $signature.Status -eq "Valid"
  }

  static [void] RemoveSignature([string]$FilePath) {
    $content = Get-Content -Path $FilePath -Raw
    $newContent = $content -replace '# SIG # Begin signature block[\s\S]*# SIG # End signature block', ''
    Set-Content -Path $FilePath -Value $newContent
  }

  static [void] SignDirectory([string]$DirectoryPath, [string]$CertPath, [string]$Filter = "*.ps1") {
    $cert = Get-ChildItem -Path $CertPath
    Get-ChildItem -Path $DirectoryPath -Filter $Filter -Recurse | ForEach-Object {
      [CodeSigner]::SetAuthenticodeSignature($_.FullName, $cert)
    }
  }

  static [X509Certificate2] GetCodeSigningCert() {
    return Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
  }
}

#region    Mainclass
# .SYNOPSIS
#  PsCraft: the giga-chad module builder and manager.
# .EXAMPLE
#  [PsModule]$module = New-PsModule "MyModule"   # Creates a new module named "MyModule" in $pwd
#  $builder = [PsCraft]::new($module.Path)
class PsCraft : ModuleManager {
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
  [PsModuleData],
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