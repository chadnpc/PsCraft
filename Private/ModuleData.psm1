#!/usr/bin/env pwsh
using namespace System.Collections.Generic
using namespace System.Collections.ObjectModel

using module .\BuildLog.psm1

# Define a class to represent individual node rules
class SchemaNode {
  [string]$Key
  [string]$TemplatePath
  [bool]$IsRequired

  SchemaNode([string]$key, [string]$templatePath) {
    $this.Key = $key
    $this.TemplatePath = $templatePath
    $this.IsRequired = $true
  }
  SchemaNode([string]$key, [string]$templatePath, [bool]$isRequired) {
    $this.Key = $key
    $this.TemplatePath = $templatePath
    $this.IsRequired = $isRequired
  }

  # Resolves paths by replacing placeholders like {mName}
  [string] ResolvePlaceholderPath([string]$ModuleName) {
    # Normalize slashes for cross-platform compatibility
    [string]$resolved = $this.TemplatePath.Replace('{mName}', $ModuleName)
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Item .).FullName, $resolved))
  }

  [string] ResolvePath([string]$ModuleName) {
    return $this.ResolvePlaceholderPath($ModuleName)
  }
}

# Define the master layout schema wrapper
class PsModuleSchema {
  [System.Collections.Generic.List[psobject]]$Files
  [System.Collections.Generic.List[psobject]]$Folders

  PsModuleSchema() {
    $this.Files = [System.Collections.Generic.List[psobject]]::new()
    $this.Folders = [System.Collections.Generic.List[psobject]]::new()
  }
  PsModuleSchema([hashtable]$Schema) {
    if ($null -eq $Schema["Files"]) { throw [ArgumentNullException]::new('$Schema["Files"]', "PsModuleSchema: Schema must have Files property" ) }
    if ($null -eq $Schema["Folders"]) { throw [ArgumentNullException]::new('$Schema["Folders"]', "PsModuleSchema: Schema must have Folders property") }
    $this.Files = [System.Collections.Generic.List[psobject]]::new()
    $Schema.Files.GetEnumerator().ForEach({
        $this.Files.Add([SchemaNode]::new($_.Key, $_.Value))
      }
    )
    $this.Folders = [System.Collections.Generic.List[psobject]]::new()
    $Schema.Folders.GetEnumerator().ForEach({
        $this.Folders.Add([SchemaNode]::new($_.Key, $_.Value))
      }
    )
  }
}

class PsModuleDefaults {
  hidden [hashtable] $_defaults = @{}

  PsModuleDefaults([string]$Name) {
    $this.SetDefaultData($this.GetDefaultData($Name, [System.Management.Automation.ModuleType]::Script))
  }
  PsModuleDefaults([string]$Name, [System.Management.Automation.ModuleType]$Type) {
    $this.SetDefaultData($this.GetDefaultData($Name, $Type))
  }
  PsModuleDefaults([string]$Name, [System.Management.Automation.ModuleType]$Type, [string]$Path) {
    $this.SetDefaultData($this.GetDefaultData($Name, $Type, [IO.DirectoryInfo]::new($Path)))
  }

  hidden [void] SetDefautltData([hashtable]$data) { $this.SetDefaultData($data) }
  hidden [hashtable] GetDefautltData([string]$Name, [System.Management.Automation.ModuleType]$Type) { return $this.GetDefaultData($Name, $Type) }
  hidden [hashtable] GetDefautltData([string]$Name, [System.Management.Automation.ModuleType]$Type, [IO.DirectoryInfo]$Path) { return $this.GetDefaultData($Name, $Type, $Path) }

  [void] SetDefaultData([hashtable]$data) {
    $this._defaults = $data
    # set properties. the format is: @{ key = content }
    $this._defaults.GetEnumerator().ForEach({ $this | Add-Member -MemberType NoteProperty -Name $_.Key -Value $_.Value -Force })
  }

  # Expose the underlying defaults as a hashtable so callers can iterate it.
  # PowerShell classes do not implement IDictionary, so [PsModuleDefaults].GetEnumerator()
  # is not defined — callers must use this accessor instead.
  [hashtable] GetDefaults() {
    return $this._defaults
  }

  [hashtable] GetDefaultData([string]$Name, [System.Management.Automation.ModuleType]$Type) {
    return $this.GetDefaultData($Name, $Type, [IO.DirectoryInfo]::new((Get-Location).Path))
  }

  [hashtable] GetDefaultData([string]$Name, [System.Management.Automation.ModuleType]$Type, [IO.DirectoryInfo]$Path) {
    if ($null -eq $Path -or [string]::IsNullOrWhiteSpace($Path.FullName)) {
      $Path = [IO.DirectoryInfo]::new((Get-Location).Path)
    }
    $authorName = [string](PsModuleBase\Get-AuthorName)
    if ([string]::IsNullOrWhiteSpace($authorName)) {
      $authorName = [Environment]::UserName
    }
    $authorEmail = [string](PsModuleBase\Get-AuthorEmail)
    if ([string]::IsNullOrWhiteSpace($authorEmail)) {
      $authorEmail = "$authorName@gmail.com"
    }
    $authorEmailPrefix = $authorEmail.Split('@')[0]
    $copyright = "Copyright {0} {1} {2}. All rights reserved." -f [string][char]169, [datetime]::Now.Year, $authorName
    $data = switch ($Type) {
      "Script" {
        @{
          Path                  = [IO.Path]::Combine((Get-Location).Path, "$Name.psd1")
          Guid                  = [guid]::NewGuid()
          Year                  = [datetime]::Now.Year
          Author                = $authorName
          UserName              = $authorEmailPrefix
          Copyright             = $copyright
          ClrVersion            = [System.Environment]::Version.ToString()
          ModuleName            = $Name
          Description           = "A longer description of the Module, its purpose, common use cases, etc."
          CompanyName           = $authorEmailPrefix
          AuthorEmail           = $authorEmail
          ModuleVersion         = '0.1.0'
          RequiredModules       = @(
            "PsModuleBase"
          )
          PowerShellVersion     = [System.Management.Automation.PSVersionInfo]::PSVersion
          Readme                = $this.SafeGetReadmeText($Name)
          License               = $this.GetLocalLicenseText()
          Builder               = $this.SafeGetScriptBlock("defaults\script\Builder.ps1")
          Tester                = $this.SafeGetScriptBlock("defaults\script\Tester.ps1")
          LocalData             = $this.SafeGetScriptBlock("defaults\script\LocalData.ps1")
          LicenseUri            = "https://$authorName.MIT-license.org"
          ProjectUri            = "https://github.com/chadnpc/$Name"
          IconUri               = 'https://github.com/user-attachments/assets/1220c30e-a309-43c3-9a80-1948dae30e09'
          rootLoader            = $this.SafeGetScriptBlock("defaults\script\RootLoader.ps1")
          ModuleTest            = $this.SafeGetScriptBlock("defaults\script\ModuleTest.ps1")
          FeatureTest           = $this.SafeGetScriptBlock("defaults\script\FeatureTest.ps1")
          IntegrationTest       = $this.SafeGetScriptBlock("defaults\script\IntegrationTest.ps1")
          ScriptAnalyzer        = $this.SafeGetScriptBlock("defaults\script\ScriptAnalyzer.ps1")
          DelWorkflowsyaml      = $this.GetModuleDelWorkflowsyaml()
          Codereviewyaml        = $this.GetModuleCodereviewyaml()
          Publishyaml           = $this.GetModulePublishyaml()
          GitIgnore             = ".env`n.env.local`nBuildOutput/`nLocalPSRepo/`nTests/results.xml`nTests/Resources/"
          CICDyaml              = $this.GetModuleCICDyaml()
          DotEnv                = "#usage example: Publish-Module -Path BuildOutput/$Name/<ModuleVersion> -NuGetApiKey `$env:NUGET_API_KEY`nNUGET_API_KEY=somethinglike_6arai6wi2rgzepnx6shcc24x2ka"
          Tags                  = [string[]]("PowerShell", $Name, [Environment]::UserName)
          ReleaseNotes          = "# Release Notes`n`n- Version_<ModuleVersion>`n- Functions ...`n- Optimizations`n"
          ProcessorArchitecture = 'None'
        }
        break
      }
      "Binary" {
        @{
          Path                  = [IO.Path]::Combine((Get-Location).Path, "$Name.psd1")
          Guid                  = [guid]::NewGuid()
          Year                  = [datetime]::Now.Year
          Author                = $authorName
          UserName              = $authorEmailPrefix
          Copyright             = $copyright
          ClrVersion            = [System.Environment]::Version.ToString()
          ModuleName            = $Name
          Description           = "A C# Binary module built with PsCraft"
          CompanyName           = $authorEmailPrefix
          AuthorEmail           = $authorEmail
          ModuleVersion         = '0.1.0'
          RequiredModules       = @(
            "PsModuleBase"
          )
          PowerShellVersion     = [System.Management.Automation.PSVersionInfo]::PSVersion
          Readme                = $this.SafeGetReadmeText($Name)
          License               = $this.GetLocalLicenseText()
          Builder               = $this.SafeGetScriptBlock("defaults\script\Builder.ps1")
          Tester                = $this.SafeGetScriptBlock("defaults\script\Tester.ps1")
          ProjectFile           = $this.SafeGetTemplateText("defaults\Binary\ProjectFile.csproj")
          CmdletClass           = $this.SafeGetTemplateText("defaults\Binary\CmdletClass.cs")
          ModuleTest            = $this.SafeGetScriptBlock("defaults\Binary\ModuleTest.ps1")
          LicenseUri            = "https://$authorName.MIT-license.org"
          ProjectUri            = "https://github.com/chadnpc/$Name"
          IconUri               = 'https://github.com/user-attachments/assets/1220c30e-a309-43c3-9a80-1948dae30e09'
          DelWorkflowsyaml      = $this.GetModuleDelWorkflowsyaml()
          Codereviewyaml        = $this.GetModuleCodereviewyaml()
          Publishyaml           = $this.GetModulePublishyaml()
          GitIgnore             = ".env`n.env.local`nBuildOutput/`nLocalPSRepo/`nTests/results.xml`nTests/Resources/`nbin/`nobj/"
          CICDyaml              = $this.GetModuleCICDyaml()
          DotEnv                = "#usage example: Publish-Module -Path BuildOutput/$Name/<ModuleVersion> -NuGetApiKey `$env:NUGET_API_KEY`nNUGET_API_KEY=somethinglike_6arai6wi2rgzepnx6shcc24x2ka"
          Tags                  = [string[]]("PowerShell", $Name, [Environment]::UserName)
          ReleaseNotes          = "# Release Notes`n`n- Version_<ModuleVersion>`n- Binary compilation`n"
          ProcessorArchitecture = 'None'
        }
        break
      }
      "Manifest" {
        @{
          Path                  = [IO.Path]::Combine((Get-Location).Path, "$Name.psd1")
          Guid                  = [guid]::NewGuid()
          Year                  = [datetime]::Now.Year
          Author                = $authorName
          UserName              = $authorEmailPrefix
          Copyright             = $copyright
          ClrVersion            = [System.Environment]::Version.ToString()
          ModuleName            = $Name
          Description           = "A Manifest module built with PsCraft"
          CompanyName           = $authorEmailPrefix
          AuthorEmail           = $authorEmail
          ModuleVersion         = '0.1.0'
          RequiredModules       = @(
            "PsModuleBase"
          )
          PowerShellVersion     = [System.Management.Automation.PSVersionInfo]::PSVersion
          Readme                = $this.SafeGetReadmeText($Name)
          License               = $this.GetLocalLicenseText()
          Builder               = $this.SafeGetScriptBlock("defaults\script\Builder.ps1")
          Tester                = $this.SafeGetScriptBlock("defaults\script\Tester.ps1")
          ModuleTest            = $this.SafeGetScriptBlock("defaults\Manifest\ModuleTest.ps1")
          LicenseUri            = "https://$authorName.MIT-license.org"
          ProjectUri            = "https://github.com/chadnpc/$Name"
          IconUri               = 'https://github.com/user-attachments/assets/1220c30e-a309-43c3-9a80-1948dae30e09'
          DelWorkflowsyaml      = $this.GetModuleDelWorkflowsyaml()
          Codereviewyaml        = $this.GetModuleCodereviewyaml()
          Publishyaml           = $this.GetModulePublishyaml()
          GitIgnore             = ".env`n.env.local`nBuildOutput/`nLocalPSRepo/`nTests/results.xml`nTests/Resources/"
          CICDyaml              = $this.GetModuleCICDyaml()
          DotEnv                = "#usage example: Publish-Module -Path BuildOutput/$Name/<ModuleVersion> -NuGetApiKey `$env:NUGET_API_KEY`nNUGET_API_KEY=somethinglike_6arai6wi2rgzepnx6shcc24x2ka"
          Tags                  = [string[]]("PowerShell", $Name, [Environment]::UserName)
          ReleaseNotes          = "# Release Notes`n`n- Version_<ModuleVersion>`n- Manifest-only release`n"
          ProcessorArchitecture = 'None'
        }
        break
      }
      "Cim" {
        @{
          Path                  = [IO.Path]::Combine((Get-Location).Path, "$Name.psd1")
          Guid                  = [guid]::NewGuid()
          Year                  = [datetime]::Now.Year
          Author                = $authorName
          UserName              = $authorEmailPrefix
          Copyright             = $copyright
          ClrVersion            = [System.Environment]::Version.ToString()
          ModuleName            = $Name
          Description           = "A CIM/WMI cmdlet wrapper module built with PsCraft"
          CompanyName           = $authorEmailPrefix
          AuthorEmail           = $authorEmail
          ModuleVersion         = '0.1.0'
          RequiredModules       = @(
            "PsModuleBase"
          )
          PowerShellVersion     = [System.Management.Automation.PSVersionInfo]::PSVersion
          Readme                = $this.SafeGetReadmeText($Name)
          License               = $this.GetLocalLicenseText()
          Builder               = $this.SafeGetScriptBlock("defaults\script\Builder.ps1")
          Tester                = $this.SafeGetScriptBlock("defaults\script\Tester.ps1")
          CimDefinition         = $this.SafeGetTemplateText("defaults\Cim\CimDefinition.cdxml")
          ModuleTest            = $this.SafeGetScriptBlock("defaults\Cim\ModuleTest.ps1")
          LicenseUri            = "https://$authorName.MIT-license.org"
          ProjectUri            = "https://github.com/chadnpc/$Name"
          IconUri               = 'https://github.com/user-attachments/assets/1220c30e-a309-43c3-9a80-1948dae30e09'
          DelWorkflowsyaml      = $this.GetModuleDelWorkflowsyaml()
          Codereviewyaml        = $this.GetModuleCodereviewyaml()
          Publishyaml           = $this.GetModulePublishyaml()
          GitIgnore             = ".env`n.env.local`nBuildOutput/`nLocalPSRepo/`nTests/results.xml`nTests/Resources/"
          CICDyaml              = $this.GetModuleCICDyaml()
          DotEnv                = "#usage example: Publish-Module -Path BuildOutput/$Name/<ModuleVersion> -NuGetApiKey `$env:NUGET_API_KEY`nNUGET_API_KEY=somethinglike_6arai6wi2rgzepnx6shcc24x2ka"
          Tags                  = [string[]]("PowerShell", $Name, [Environment]::UserName)
          ReleaseNotes          = "# Release Notes`n`n- Version_<ModuleVersion>`n- CIM CDXML integration`n"
          ProcessorArchitecture = 'None'
        }
        break
      }
      default {
        [BuildLog]::WriteWarning("Unknown module type: $Type. Returning null.")
        $null
        break
      }
    }
    $getter = [scriptblock]::Create("return [System.Management.Automation.ModuleType]::$Type")
    $this.PsObject.Properties.Add([PsScriptproperty]::New('ModuleType', $getter, { throw 'ModuleType is read-only' }))
    return $data
  }
  [PsModuleSchema] GetModuleSchema() {
    return $this.GetModuleSchema($this.ModuleName, [System.Management.Automation.ModuleType]::Script)
  }
  [PsModuleSchema] GetModuleSchema([string]$Name, [System.Management.Automation.ModuleType]$Type) {
    $schema = switch ($Type) {
      "Script" {
        @{
          Files   = @{
            Path             = './{mName}.psd1'
            Tester           = './Test-Module.ps1'
            Builder          = './build.ps1'
            License          = './LICENSE'
            Readme           = './README.md'
            Manifest         = './{mName}.psd1'
            LocalData        = "./$((Get-Culture).Name)/{mName}.strings.psd1"
            rootLoader       = './{mName}.psm1'
            ScriptAnalyzer   = './PSScriptAnalyzerSettings.psd1'
            ModuleTest       = './Tests/{mName}.Module.Tests.ps1'
            FeatureTest      = './Tests/{mName}.Features.Tests.ps1'
            IntegrationTest  = './Tests/{mName}.Integration.Tests.ps1'
            DelWorkflowsyaml = './.github/workflows/delete_old_workflow_runs.yaml'
            Codereviewyaml   = './.github/workflows/codereview.yaml'
            Publishyaml      = './.github/workflows/publish.yaml'
            GitIgnore        = './.gitignore'
            CICDyaml         = './.github/workflows/build_module.yaml'
            DotEnv           = './.env.example'
          }
          Folders = @{
            root      = './'
            tests     = './Tests'
            public    = './Public'
            private   = './Private'
            LocalData = "./$((Get-Culture).Name)"
            workflows = './.github/workflows'
          }
        }
        break
      }
      "Binary" {
        @{
          Files   = @{
            Path        = './{mName}.psd1'
            Tester      = './Test-Module.ps1'
            Builder     = './build.ps1'
            License     = './LICENSE'
            Readme      = './README.md'
            Manifest    = './{mName}.psd1'
            ProjectFile = './src/{mName}.csproj'
            CmdletClass = './src/GetInfoCmdlet.cs'
            ModuleTest  = './Tests/{mName}.Tests.ps1'
            GitIgnore   = './.gitignore'
            CICDyaml    = './.github/workflows/build_module.yaml'
            DotEnv      = './.env.example'
          }
          Folders = @{
            root      = './'
            src       = './src'
            tests     = './Tests'
            workflows = './.github/workflows'
          }
        }
        break
      }
      "Manifest" {
        @{
          Files   = @{
            Path       = './{mName}.psd1'
            Tester     = './Test-Module.ps1'
            Builder    = './build.ps1'
            License    = './LICENSE'
            Readme     = './README.md'
            Manifest   = './{mName}.psd1'
            ModuleTest = './Tests/{mName}.Tests.ps1'
            GitIgnore  = './.gitignore'
            CICDyaml   = './.github/workflows/build_module.yaml'
            DotEnv     = './.env.example'
          }
          Folders = @{
            root      = './'
            tests     = './Tests'
            workflows = './.github/workflows'
          }
        }
        break
      }
      "Cim" {
        @{
          Files   = @{
            Path          = './{mName}.psd1'
            Tester        = './Test-Module.ps1'
            Builder       = './build.ps1'
            License       = './LICENSE'
            Readme        = './README.md'
            Manifest      = './{mName}.psd1'
            CimDefinition = './Cim/{mName}.cdxml'
            ModuleTest    = './Tests/{mName}.Tests.ps1'
            GitIgnore     = './.gitignore'
            CICDyaml      = './.github/workflows/build_module.yaml'
            DotEnv        = './.env.example'
          }
          Folders = @{
            root      = './'
            cim       = './Cim'
            tests     = './Tests'
            workflows = './.github/workflows'
          }
        }
        break
      }
      default {
        [BuildLog]::WriteWarning("Unknown module type: $Type. Returning null.")
        $null
        break
      }
    }
    return [PsModuleSchema]::new($schema)
  }

  hidden [scriptblock] SafeGetScriptBlock([string]$Ps1filePath) {
    try {
      return $this.GetScriptBlock($Ps1filePath)
    }
    catch {
      [BuildLog]::WriteWarning("Script block retrieval failed for $Ps1filePath`n$($_ | Format-List * -Force | Out-String)")
      return [scriptblock]::Create("{}");
    }
  }
  hidden [string] SafeGetTemplateText([string]$filePath) {
    try {
      return $this.GetTemplateText($filePath)
    }
    catch {
      [BuildLog]::WriteWarning("Template text retrieval failed for $filePath`n$($_ | Format-List * -Force | Out-String)")
      return ""
    }
  }
  hidden [string] SafeGetReadmeText([string]$ModuleName) {
    try {
      return (PsModuleBase\Get-ModuleReadmeText -n $ModuleName 2>$null)
    }
    catch {
      [BuildLog]::WriteWarning("Readme text retrieval failed for $ModuleName`n$($_ | Format-List * -Force | Out-String)")
      return ""
    }
  }
  hidden [string] SafeGetLicenseText() {
    try {
      return (PsModuleBase\Get-ModuleLicenseText 2>$null)
    }
    catch {
      [BuildLog]::WriteWarning("License text retrieval failed`n$($_ | Format-List * -Force | Out-String)")
      return ""
    }
  }
  hidden [string] GetLocalLicenseText() {
    try {
      return [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $Script:PSScriptRoot) "LICENSE"))
    }
    catch {
      [BuildLog]::WriteWarning("Local license text retrieval failed`n$($_ | Format-List * -Force | Out-String)")
      return ""
    }
  }

  [string] GetModuleCICDyaml() {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("77u/bmFtZTogQnVpbGQgTW9kdWxlCm9uOiBbd29ya2Zsb3dfZGlzcGF0Y2hdCmRlZmF1bHRzOgogIHJ1bjoKICAgIHNoZWxsOiBwd3NoCgpqb2JzOgogIGJ1aWxkOgogICAgbmFtZTogUnVucyBvbgogICAgcnVucy1vbjogJHt7IG1hdHJpeC5vcyB9fQogICAgc3RyYXRlZ3k6CiAgICAgIGZhaWwtZmFzdDogZmFsc2UKICAgICAgbWF0cml4OgogICAgICAgIG9zOiBbd2luZG93cy1sYXRlc3QsIG1hY09TLWxhdGVzdF0KICAgIHN0ZXBzOgogICAgICAtIHVzZXM6IGFjdGlvbnMvY2hlY2tvdXRAdjMKICAgICAgLSBuYW1lOiBCdWlsZAogICAgICAgIHJ1bjogLi9idWlsZC5wczEgLVRhc2sgVGVzdA=="));
  }
  [string] GetModuleCodereviewyaml() {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("bmFtZTogQ29kZSBSZXZpZXcKcGVybWlzc2lvbnM6CiAgY29udGVudHM6IHJlYWQKICBwdWxsLXJlcXVlc3RzOiB3cml0ZQoKb246CiAgcHVsbF9yZXF1ZXN0OgogICAgdHlwZXM6IFtvcGVuZWQsIHJlb3BlbmVkLCBzeW5jaHJvbml6ZV0KCmpvYnM6CiAgdGVzdDoKICAgIHJ1bnMtb246IHVidW50dS1sYXRlc3QKICAgIHN0ZXBzOgogICAgICAtIHVzZXM6IGFuYzk1L0NoYXRHUFQtQ29kZVJldmlld0B2MS4wLjEyCiAgICAgICAgZW52OgogICAgICAgICAgR0lUSFVCX1RPS0VOOiAke3sgc2VjcmV0cy5HSVRIVUJfVE9LRU4gfX0KICAgICAgICAgIE9QRU5BSV9BUElfS0VZOiAke3sgc2VjcmV0cy5PUEVOQUlfQVBJX0tFWSB9fQogICAgICAgICAgTEFOR1VBR0U6IEVuZ2xpc2gKICAgICAgICAgIE9QRU5BSV9BUElfRU5EUE9JTlQ6IGh0dHBzOi8vYXBpLm9wZW5haS5jb20vdjEKICAgICAgICAgIE1PREVMOiBncHQtNG8gIyBodHRwczovL3BsYXRmb3JtLm9wZW5haS5jb20vZG9jcy9tb2RlbHMKICAgICAgICAgIFBST01QVDogUGxlYXNlIGNoZWNrIGlmIHRoZXJlIGFyZSBhbnkgY29uZnVzaW9ucyBvciBpcnJlZ3VsYXJpdGllcyBpbiB0aGUgZm9sbG93aW5nIGNvZGUgZGlmZgogICAgICAgICAgdG9wX3A6IDEKICAgICAgICAgIHRlbXBlcmF0dXJlOiAxCiAgICAgICAgICBtYXhfdG9rZW5zOiAxMDAwMAogICAgICAgICAgTUFYX1BBVENIX0xFTkdUSDogMTAwMDAgIyBpZiB0aGUgcGF0Y2gvZGlmZiBsZW5ndGggaXMgbGFyZ2UgdGhhbiBNQVhfUEFUQ0hfTEVOR1RILCB3aWxsIGJlIGlnbm9yZWQgYW5kIHdvbid0IHJldmlldy4="));
  }
  [string] GetModulePublishyaml() {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("bmFtZTogR2l0SHViIHJlbGVhc2UgYW5kIFB1Ymxpc2gKb246IFt3b3JrZmxvd19kaXNwYXRjaF0KZGVmYXVsdHM6CiAgcnVuOgogICAgc2hlbGw6IHB3c2gKam9iczoKICB1cGxvYWQtcGVzdGVyLXJlc3VsdHM6CiAgICBuYW1lOiBSdW4gUGVzdGVyIGFuZCB1cGxvYWQgcmVzdWx0cwogICAgcnVucy1vbjogdWJ1bnR1LWxhdGVzdAogICAgc3RlcHM6CiAgICAgIC0gdXNlczogYWN0aW9ucy9jaGVja291dEB2MwogICAgICAtIG5hbWU6IFRlc3Qgd2l0aCBQZXN0ZXIKICAgICAgICBzaGVsbDogcHdzaAogICAgICAgIHJ1bjogLi9UZXN0LU1vZHVsZS5wczEKICAgICAgLSBuYW1lOiBVcGxvYWQgdGVzdCByZXN1bHRzCiAgICAgICAgdXNlczogYWN0aW9ucy91cGxvYWQtYXJ0aWZhY3RAdjMKICAgICAgICB3aXRoOgogICAgICAgICAgbmFtZTogdWJ1bnR1LVVuaXQtVGVzdHMKICAgICAgICAgIHBhdGg6IFVuaXQuVGVzdHMueG1sCiAgICBpZjogJHt7IGFsd2F5cygpIH19CiAgcHVibGlzaC10by1nYWxsZXJ5OgogICAgbmFtZTogUHVibGlzaCB0byBQb3dlclNoZWxsIEdhbGxlcnkKICAgIHJ1bnMtb246IHVidW50dS1sYXRlc3QKICAgIHN0ZXBzOgogICAgICAtIHVzZXM6IGFjdGlvbnMvY2hlY2tvdXRAdjMKICAgICAgLSBuYW1lOiBQdWJsaXNoCiAgICAgICAgZW52OgogICAgICAgICAgR2l0SHViUEFUOiAke3sgc2VjcmV0cy5HaXRIdWJQQVQgfX0KICAgICAgICAgIE5VR0VUQVBJS0VZOiAke3sgc2VjcmV0cy5OVUdFVEFQSUtFWSB9fQogICAgICAgIHJ1bjogLi9idWlsZC5wczEgLVRhc2sgRGVwbG95"));
  }
  [string] GetModuleDelWorkflowsyaml() {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("bmFtZTogRGVsZXRlIG9sZCB3b3JrZmxvdyBydW5zCm9uOgogIHdvcmtmbG93X2Rpc3BhdGNoOgogICAgaW5wdXRzOgogICAgICBkYXlzOgogICAgICAgIGRlc2NyaXB0aW9uOiAnRGF5cy13b3J0aCBvZiBydW5zIHRvIGtlZXAgZm9yIGVhY2ggd29ya2Zsb3cnCiAgICAgICAgcmVxdWlyZWQ6IHRydWUKICAgICAgICBkZWZhdWx0OiAnMCcKICAgICAgbWluaW11bV9ydW5zOgogICAgICAgIGRlc2NyaXB0aW9uOiAnTWluaW11bSBydW5zIHRvIGtlZXAgZm9yIGVhY2ggd29ya2Zsb3cnCiAgICAgICAgcmVxdWlyZWQ6IHRydWUKICAgICAgICBkZWZhdWx0OiAnMScKICAgICAgZGVsZXRlX3dvcmtmbG93X3BhdHRlcm46CiAgICAgICAgZGVzY3JpcHRpb246ICdOYW1lIG9yIGZpbGVuYW1lIG9mIHRoZSB3b3JrZmxvdyAoaWYgbm90IHNldCwgYWxsIHdvcmtmbG93cyBhcmUgdGFyZ2V0ZWQpJwogICAgICAgIHJlcXVpcmVkOiBmYWxzZQogICAgICBkZWxldGVfd29ya2Zsb3dfYnlfc3RhdGVfcGF0dGVybjoKICAgICAgICBkZXNjcmlwdGlvbjogJ0ZpbHRlciB3b3JrZmxvd3MgYnkgc3RhdGU6IGFjdGl2ZSwgZGVsZXRlZCwgZGlzYWJsZWRfZm9yaywgZGlzYWJsZWRfaW5hY3Rpdml0eSwgZGlzYWJsZWRfbWFudWFsbHknCiAgICAgICAgcmVxdWlyZWQ6IHRydWUKICAgICAgICBkZWZhdWx0OiAiQUxMIgogICAgICAgIHR5cGU6IGNob2ljZQogICAgICAgIG9wdGlvbnM6CiAgICAgICAgICAtICJBTEwiCiAgICAgICAgICAtIGFjdGl2ZQogICAgICAgICAgLSBkZWxldGVkCiAgICAgICAgICAtIGRpc2FibGVkX2luYWN0aXZpdHkKICAgICAgICAgIC0gZGlzYWJsZWRfbWFudWFsbHkKICAgICAgZGVsZXRlX3J1bl9ieV9jb25jbHVzaW9uX3BhdHRlcm46CiAgICAgICAgZGVzY3JpcHRpb246ICdSZW1vdmUgcnVucyBiYXNlZCBvbiBjb25jbHVzaW9uOiBhY3Rpb25fcmVxdWlyZWQsIGNhbmNlbGxlZCwgZmFpbHVyZSwgc2tpcHBlZCwgc3VjY2VzcycKICAgICAgICByZXF1aXJlZDogdHJ1ZQogICAgICAgIGRlZmF1bHQ6ICJBTEwiCiAgICAgICAgdHlwZTogY2hvaWNlCiAgICAgICAgb3B0aW9uczoKICAgICAgICAgIC0gIkFMTCIKICAgICAgICAgIC0gIlVuc3VjY2Vzc2Z1bDogYWN0aW9uX3JlcXVpcmVkLGNhbmNlbGxlZCxmYWlsdXJlLHNraXBwZWQiCiAgICAgICAgICAtIGFjdGlvbl9yZXF1aXJlZAogICAgICAgICAgLSBjYW5jZWxsZWQKICAgICAgICAgIC0gZmFpbHVyZQogICAgICAgICAgLSBza2lwcGVkCiAgICAgICAgICAtIHN1Y2Nlc3MKICAgICAgZHJ5X3J1bjoKICAgICAgICBkZXNjcmlwdGlvbjogJ0xvZ3Mgc2ltdWxhdGVkIGNoYW5nZXMsIG5vIGRlbGV0aW9ucyBhcmUgcGVyZm9ybWVkJwogICAgICAgIHJlcXVpcmVkOiBmYWxzZQoKam9iczoKICBkZWxfcnVuczoKICAgIHJ1bnMtb246IHVidW50dS1sYXRlc3QKICAgIHBlcm1pc3Npb25zOgogICAgICBhY3Rpb25zOiB3cml0ZQogICAgICBjb250ZW50czogcmVhZAogICAgc3RlcHM6CiAgICAgIC0gbmFtZTogRGVsZXRlIHdvcmtmbG93IHJ1bnMKICAgICAgICB1c2VzOiBNYXR0cmFrcy9kZWxldGUtd29ya2Zsb3ctcnVuc0B2MgogICAgICAgIHdpdGg6CiAgICAgICAgICB0b2tlbjogJHt7IGdpdGh1Yi50b2tlbiB9fQogICAgICAgICAgcmVwb3NpdG9yeTogJHt7IGdpdGh1Yi5yZXBvc2l0b3J5IH19CiAgICAgICAgICByZXRhaW5fZGF5czogJHt7IGdpdGh1Yi5ldmVudC5pbnB1dHMuZGF5cyB9fQogICAgICAgICAga2VlcF9taW5pbXVtX3J1bnM6ICR7eyBnaXRodWIuZXZlbnQuaW5wdXRzLm1pbmltdW1fcnVucyB9fQogICAgICAgICAgZGVsZXRlX3dvcmtmbG93X3BhdHRlcm46ICR7eyBnaXRodWIuZXZlbnQuaW5wdXRzLmRlbGV0ZV93b3JrZmxvd19wYXR0ZXJuIH19CiAgICAgICAgICBkZWxldGVfd29ya2Zsb3dfYnlfc3RhdGVfcGF0dGVybjogJHt7IGdpdGh1Yi5ldmVudC5pbnB1dHMuZGVsZXRlX3dvcmtmbG93X2J5X3N0YXRlX3BhdHRlcm4gfX0KICAgICAgICAgIGRlbGV0ZV9ydW5fYnlfY29uY2x1c2lvbl9wYXR0ZXJuOiA+LQogICAgICAgICAgICAke3sKICAgICAgICAgICAgICBzdGFydHNXaXRoKGdpdGh1Yi5ldmVudC5pbnB1dHMuZGVsZXRlX3J1bl9ieV9jb25jbHVzaW9uX3BhdHRlcm4sICdVbnN1Y2Nlc3NmdWw6JykKICAgICAgICAgICAgICAmJiAnYWN0aW9uX3JlcXVpcmVkLGNhbmNlbGxlZCxmYWlsdXJlLHNraXBwZWQnCiAgICAgICAgICAgICAgfHwgZ2l0aHViLmV2ZW50LmlucHV0cy5kZWxldGVfcnVuX2J5X2NvbmNsdXNpb25fcGF0dGVybgogICAgICAgICAgICB9fQogICAgICAgICAgZHJ5X3J1bjogJHt7IGdpdGh1Yi5ldmVudC5pbnB1dHMuZHJ5X3J1biB9fQ=="));
  }
  [ScriptBlock] GetScriptBlock([string]$Ps1filePath) {
    [string]$resolved = [PsModuleBase]::GetResolvedPath([IO.Path]::Combine($Script:PSScriptRoot, $Ps1filePath))
    [ValidateNotNullOrWhiteSpace()][string]$resolved = $resolved
    $string = [IO.File]::ReadAllText($Resolved)
    [ValidateNotNullOrWhiteSpace()][string]$string = $string
    return [scriptblock]::Create("$string")
  }
  [string] GetTemplateText([string]$filePath) {
    [string]$resolved = [PsModuleBase]::GetResolvedPath([IO.Path]::Combine($Script:PSScriptRoot, $filePath))
    [ValidateNotNullOrWhiteSpace()][string]$resolved = $resolved
    return [IO.File]::ReadAllText($resolved)
  }
}

class PsModuleData : System.Collections.Generic.Dictionary[string, Object] {
  [ValidateNotNullOrWhiteSpace()][string]$Name
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$Path
  [ReadOnlyCollection[ModuleFile]]$Files
  [ReadOnlyCollection[ModuleFolder]]$Folders
  hidden [PsModuleDefaults]$defaults

  PsModuleData([string]$Name, [System.Management.Automation.ModuleType]$Type, [IO.DirectoryInfo]$Path) {
    $this.Name = [string]::IsNullOrWhiteSpace($Name) ? [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetRandomFileName()) : $Name
    $this.defaults = [PsModuleDefaults]::new($this.Name, $Type, $Path)
    $this.Path = [System.IO.Path]::Combine([PsModuleBase]::GetunResolvedPath($this.GetModuleroot($Path)), $this.Name);

    $schema = $this.defaults.GetModuleSchema($this.Name, $Type)
    $this.Files = [PsModuleData]::GetModuleFiles($this.Name, $this.Path, $schema)
    $this.Folders = [PsModuleData]::GetModuleSubFolders($this.Name, $this.Path, $schema)
  }
  PsModuleData([string]$Name, [System.Management.Automation.ModuleType]$Type, [object[]]$Files, [object[]]$Folders) {
    $this.Name = $Name
    $this.defaults = [PsModuleDefaults]::new($this.Name, $Type)
    $this.Path = [System.IO.Path]::Combine([PsModuleBase]::GetunResolvedPath($this.GetModuleroot($this.defaults.Path)), $this.Name);

    $this.Files = PsModuleBase\New-ReadOnlyCollection -list $Files
    $this.Folders = PsModuleBase\New-ReadOnlyCollection -list $Folders
  }
  static [ReadOnlyCollection[ModuleFile]] GetModuleFiles([string]$ModName, [string]$ModRoot, [PsModuleSchema]$Schema) {
    [ValidateNotNullOrWhiteSpace()][string]$ModRoot = $ModRoot
    [ValidateNotNullOrWhiteSpace()][string]$ModName = $ModName
    $l = @(); $Schema.Files.GetEnumerator().ForEach({
        $path = $_.TemplatePath.Replace('./', $ModRoot + '/').Replace('{mName}', $ModName)
        $l += [ModuleFile]::new($_.Key, [System.IO.Path]::GetFullPath($path))
      }
    )
    return PsModuleBase\New-ReadOnlyCollection -list $l
  }
  static [ReadOnlyCollection[ModuleFolder]] GetModuleSubFolders([string]$ModName, [string]$ModRoot, [PsModuleSchema]$Schema) {
    [ValidateNotNullOrWhiteSpace()][string]$ModRoot = $ModRoot
    $l = @(); $Schema.Folders.GetEnumerator().ForEach({
        $path = $_.TemplatePath.Replace('./', $ModRoot + '/').Replace('{mName}', $ModName)
        $l += [ModuleFolder]::new($_.Key, [System.IO.Path]::GetFullPath($path))
      }
    )
    return PsModuleBase\New-ReadOnlyCollection -list $l
  }
  [void] Set($k, $v) {
    if ($this.ContainsKey($k)) {
      $this[$k] = $v
    }
    else {
      $this.Add($k, $v)
    }
  }
  [void] Format() {
    $keysToFormat = @($this.Keys).Where({
        $this[$_] -is [scriptblock] -or $this[$_] -is [string]
      })
    foreach ($k in $keysToFormat) {
      try {
        $formatted = Invoke-Formatter -ScriptDefinition $this[$k].ToString() -Verbose:$false
        if ($this[$k] -is [scriptblock]) {
          $this[$k] = [scriptblock]::Create($formatted)
        }
        else {
          $this[$k] = $formatted
        }
      }
      catch {
        # keep original on formatter failure
        [BuildLog]::WriteWarning("Formatter failed for key: $k`n$($_ | Format-List * -Force | Out-String)")
      }
    }
  }
  static [object] ReplaceTemplates([object]$data) {
    # Normalize input: accept either a dictionary (PsModuleData / hashtable)
    # directly, or an array/collection whose first dictionary element is used.
    # The previous implementation iterated the *array* with .Foreach(), which
    # made $_ be the dictionary itself (no .Key / .Value), producing the
    # "A null key is not allowed in a hash literal" error.
    $dict = $null
    if ($data -is [System.Collections.IDictionary]) {
      $dict = $data
    } elseif ($null -ne $data -and $data -isnot [string] -and $data -is [System.Collections.IEnumerable]) {
      foreach ($x in $data) {
        if ($x -is [System.Collections.IDictionary]) { $dict = $x; break }
      }
    }
    if ($null -eq $dict) {
      [BuildLog]::WriteWarning("ReplaceTemplates: input is not a dictionary; nothing to replace.")
      return $data
    }

    # Snapshot all entries into a plain hashtable used as the placeholder
    # lookup table. Skip entries with a null key to stay safe.
    $hashtable = @{}
    foreach ($entry in $dict.GetEnumerator()) {
      if ($null -eq $entry.Key) { continue }
      $hashtable[$entry.Key] = $entry.Value
    }
    $keys = @($hashtable.Keys)

    # Collect template entries: values that are strings or scriptblocks
    # potentially containing <Key> placeholder tokens.
    $templates = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $dict.GetEnumerator()) {
      if ($null -eq $entry.Key -or $null -eq $entry.Value) { continue }
      $vt = $entry.Value.GetType().Name
      if ($vt -in ('String', 'ScriptBlock')) {
        [void]$templates.Add(([PSCustomObject]@{ Key = $entry.Key; Type = $vt }))
      }
    }

    foreach ($item in $templates) {
      [string]$n = $item.Key
      [string]$t = $item.Type
      if ([string]::IsNullOrWhiteSpace($n)) { [BuildLog]::WriteWarning("`$item.Key is empty"); continue }
      if ([string]::IsNullOrWhiteSpace($t)) { [BuildLog]::WriteWarning("`$item.Type is empty"); continue }
      switch ($t) {
        'ScriptBlock' {
          if ($null -eq $hashtable[$n]) { break }
          $str = $hashtable[$n].ToString()
          foreach ($k in $keys) {
            if ($str -match "<$k>") {
              $repl = if ($null -ne $hashtable[$k]) { "$($hashtable[$k])" } else { '' }
              $str = $str.Replace("<$k>", $repl)
              $dict[$n] = [scriptblock]::Create($str)
              Write-Debug "`$module.data.$n Replaced <$k>"
            }
          }
          break
        }
        'String' {
          if ($null -eq $hashtable[$n]) { break }
          $str = [string]$hashtable[$n]
          foreach ($k in $keys) {
            if ($str -match "<$k>") {
              $repl = if ($null -ne $hashtable[$k]) { "$($hashtable[$k])" } else { '' }
              $str = $str.Replace("<$k>", $repl)
              $dict[$n] = $str
              Write-Debug "`$module.data.$n Replaced <$k>"
            }
          }
          break
        }
        default {
          [BuildLog]::WriteWarning("Unknown Type: $t")
          continue
        }
      }
    }
    return $dict
  }
  [string] GetModuleroot([IO.DirectoryInfo]$Path) {
    [string]$mroot = switch ($true) {
      $(![string]::IsNullOrWhiteSpace($Path.FullName)) {
        $Path.FullName;
        break
      }
      $(![string]::IsNullOrEmpty($Path.FullName)) {
        $fp = ([System.IO.Path]::GetFileNameWithoutExtension($Path.FullName) -ne $this.Name) ? [System.IO.FileInfo][System.IO.Path]::Combine(([System.IO.Path]::GetDirectoryName($Path.FullName) | Split-Path), "$($this.Name).psd1") : $Path.FullName
        [System.IO.Path]::GetDirectoryName($fp)
        break
      }
      default { (Resolve-Path .).Path }
    }
    return $mroot
  }
  [string] ToString() {
    return "@{$($this.Count) entries}"
  }
}
