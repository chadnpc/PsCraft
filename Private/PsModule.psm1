using namespace System.IO
using namespace System.Management.Automation
using namespace System.Collections.Generic
using namespace System.Collections.ObjectModel

using module .\Enums.psm1
using module .\PsModuleData.psm1
using module .\ModuleManager.psm1

class PsModule : IDisposable {
  [ValidateNotNullOrEmpty()] [String]$Name;
  [ValidateNotNullOrEmpty()] [IO.DirectoryInfo]$Path;
  [PsModuleData] $data;
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
            default { $(Resolve-Path .).Path }
          })
      ), $mName)
    [void][PsModuleBase]::validatePath($mroot); $o.Value.Path = $mroot
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
    @{
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
    }.GetEnumerator().ForEach({
        $o.Value.Files += [ModuleFile]::new($_.Name, $_.Value)
      }
    )
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
      $nF = @(); $p = $_.value; while (!$p.Exists) { $nF += $p; $p = $p.Parent }
      [Array]::Reverse($nF);
      foreach ($d in $nF) {
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