function Get-LocalModule {
  # .SYNOPSIS
  # Gets basic details of an Installed Psmodule
  # .DESCRIPTION
  # Its like using Get-InstalledModule but you can even find unregistered/"manually Installed" modules. (as long as they are in any of $env:PSModulePath folders)
  # .EXAMPLE
  # Get-LocalModule psake | Select-Object -ExpandProperty Path | Import-Module -Verbose
  [CmdletBinding()]
  [OutputType([LocalPsModule])]
  param (
    # The name of the installed modul to search on the machine.
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    # The required module version. You don't use this parameter,
    # then this cmdlet will search for the highest version from the specified scope.
    [Parameter(Mandatory = $false, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [version]$version,

    # If you don't use this parameter then, this cmdlet uses LocalMachine as a default scope.
    [Parameter(Mandatory = $false, Position = 2)]
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$Scope
  )
  begin {
    $PsModule = $null
    class LocalPsModule {
      [string]$Name
      [string]$version
      [IO.FileInfo]$Psd1
      [System.String]$Scope
      [IO.DirectoryInfo]$Path
      [bool]$Exists = $false
      [psobject]$Info = $null
      [bool]$IsReadOnly = $false
      [bool]$HasVersiondirs = $false

      LocalPsModule([string]$Name) {
        $ModuleBase = $null; $AvailModls = Get-Module -ListAvailable -Name $Name -ErrorAction Ignore
        if ($null -ne $AvailModls) { $ModuleBase = ($AvailModls.ModuleBase -as [string[]])[0] }
        if ($null -ne $ModuleBase) {
          $Module = $this::Find($Name, [IO.DirectoryInfo]::New($ModuleBase))
          $this.IsReadOnly = $Module.IsReadOnly; $this.version = $Module.version;
          $this.Exists = $Module.Exists; $this.Scope = $Module.Scope
          $this.Path = $Module.Path
          $this.Psd1 = $Module.Psd1
          $this.Name = $Module.Name
          $this.Info = $Module.Info
        } else {
          $this._Init_($Name, 'LocalMachine', $null)
        }
      }
      LocalPsModule([string]$Name, [string]$scope) {
        $this._Init_($Name, $scope, $null)
      }
      LocalPsModule([string]$Name, [version]$version) {
        $this._Init_($Name, $null, $version)
      }
      LocalPsModule([string]$Name, [string]$scope, [version]$version) {
        $this._Init_($Name, $scope, $version)
      }
      static hidden [PSCustomObject] Find([string]$Name) {
        [ValidateNotNullOrEmpty()][string]$Name = $Name
        $ModuleBase = $null; $AvailModls = Get-Module -ListAvailable -Name $Name -ErrorAction Ignore
        if ($null -ne $AvailModls) { $ModuleBase = ($AvailModls.ModuleBase -as [string[]])[0] }
        if ($null -ne $ModuleBase) {
          return [LocalPsModule]::Find($Name, [IO.DirectoryInfo]::New($ModuleBase))
        } else {
          return [LocalPsModule]::Find($Name, 'LocalMachine', $null)
        }
      }
      static hidden [PSCustomObject] Find([string]$Name, [IO.DirectoryInfo]$ModuleBase) {
        [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$ModuleBase = $ModuleBase
        $result = [PSCustomObject]@{
          Name       = [string]::Empty
          Path       = $null
          Psd1       = $null
          Info       = @{}
          scope      = 'LocalMachine'
          Exists     = $false
          Version    = [version]::New()
          IsReadOnly = $false
        }
        $ModulePsd1 = ($ModuleBase.GetFiles().Where({ $_.Name -like "$Name*" -and $_.Extension -eq '.psd1' }))[0]
        if ($null -eq $ModulePsd1) { return $result }
        $result.Info = [LocalPsModule]::ReadPowershellDataFile($ModulePsd1.FullName)
        $result.Name = $ModulePsd1.BaseName
        $result.Psd1 = $ModulePsd1
        $result.Path = if ($result.Psd1.Directory.Name -as [version] -is [version]) { $result.Psd1.Directory.Parent } else { $result.Psd1.Directory }
        $result.Exists = $ModulePsd1.Exists
        $result.Version = $result.Info.ModuleVersion -as [version]
        $result.IsReadOnly = $ModulePsd1.IsReadOnly
        return $result
      }
      static hidden [PSCustomObject] Find([string]$Name, [string]$scope, [version]$version) {
        $ModuleScope = $scope; if ([string]::IsNullOrWhiteSpace($ModuleScope)) { $ModuleScope = 'LocalMachine' }
        $Module = $null; $PsModule_Paths = $([LocalPsModule]::Get_Module_Paths($ModuleScope) |
            ForEach-Object { [IO.DirectoryInfo]::New("$_") } | Where-Object { $_.Exists }
        ).GetDirectories().Where({ $_.Name -eq $Name });
        if ($PsModule_Paths.count -gt 0) {
          $Get_versionDir = [scriptblock]::Create('param([IO.DirectoryInfo[]]$direcrory) return ($direcrory | ForEach-Object { $_.GetDirectories() | Where-Object { $_.Name -as [version] -is [version] } })')
          $has_versionDir = $Get_versionDir.Invoke($PsModule_Paths).count -gt 0
          $ModulePsdFiles = $PsModule_Paths | ForEach-Object {
            if ($has_versionDir) {
              [string]$MaxVersion = ($Get_versionDir.Invoke([IO.DirectoryInfo]::New("$_")) | Select-Object @{l = 'version'; e = { $_.BaseName -as [version] } } | Measure-Object -Property version -Maximum).Maximum
              [IO.FileInfo]::New([IO.Path]::Combine("$_", $MaxVersion, $_.BaseName + '.psd1'))
            } else {
              [IO.FileInfo]::New([IO.Path]::Combine("$_", $_.BaseName + '.psd1'))
            }
          } | Where-Object { $_.Exists }
          $Get_ModuleVersion = {
            param ([Parameter(Mandatory)][string]$Psd1Path)
            $data = [LocalPsModule]::ReadPowershellDataFile($Psd1Path)
            $_ver = $data.ModuleVersion; if ($null -eq $_ver) { $_ver = [version][IO.FileInfo]::New($Psd1Path).Directory.Name }
            return $_ver
          }
          $Req_ModulePsd1 = if ($null -eq $version) {
            $ModulePsdFiles | Sort-Object -Property version -Descending | Select-Object -First 1
          } else {
            $ModulePsdFiles | Where-Object { $Get_ModuleVersion.Invoke($_.FullName) -eq $version }
          }
          $Module = [LocalPsModule]::Find($Req_ModulePsd1.Name, $Req_ModulePsd1.Directory)
        }
        return $Module
      }
      static [string[]] Get_Module_Paths() {
        return [LocalPsModule]::Get_Module_Paths($null)
      }
      static [string[]] Get_Module_Paths([string]$scope) {
        [string[]]$_Module_Paths = [System.Environment]::GetEnvironmentVariable('PSModulePath').Split([IO.Path]::PathSeparator)
        if ([string]::IsNullOrWhiteSpace($scope)) { return $_Module_Paths }
        [ValidateSet('CurrentUser', 'LocalMachine')][string]$scope = $scope
        if (!(Get-Variable -Name IsWindows -ErrorAction Ignore) -or $(Get-Variable IsWindows -ValueOnly)) {
          $psv = Get-Variable PSVersionTable -ValueOnly
          $allUsers_path = Join-Path -Path $env:ProgramFiles -ChildPath $(if ($psv.ContainsKey('PSEdition') -and $psv.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' })
          if ($Scope -eq 'CurrentUser') { $_Module_Paths = $_Module_Paths.Where({ $_ -notlike "*$($allUsers_path | Split-Path)*" -and $_ -notlike "*$env:SystemRoot*" }) }
        } else {
          $allUsers_path = Split-Path -Path ([System.Management.Automation.Platform]::SelectProductNameForDirectory('SHARED_MODULES')) -Parent
          if ($Scope -eq 'CurrentUser') { $_Module_Paths = $_Module_Paths.Where({ $_ -notlike "*$($allUsers_path | Split-Path)*" -and $_ -notlike "*/var/lib/*" }) }
        }
        return $_Module_Paths
      }
      static hidden [PSObject] ReadPowershellDataFile([string]$Psd1Path) {
        $null = Get-Item -Path $Psd1Path -ErrorAction Stop
        $data = New-Object PSObject; $text = [IO.File]::ReadAllText("$Psd1Path")
        $data = [scriptblock]::Create("$text").Invoke()
        return $data
      }
      hidden _Init_ ([string]$Name, [string]$scope, [version]$version) {
        [ValidateSet('CurrentUser', 'LocalMachine')][string]$scope = $scope
        $Module = [LocalPsModule]::Find($Name, $scope, $version); $this.IsReadOnly = $Module.IsReadOnly;
        $this.version = $Module.version; $this.Exists = $Module.Exists; $this.Scope = $Module.Scope
        $this.Path = $Module.Path
        $this.Psd1 = $Module.Psd1
        $this.Name = $Module.Name
        $this.Info = $Module.Info
      }
    }
  }
  process {
    $PsModule = switch ($true) {
      $($PSBoundParameters.ContainsKey('version') -and $PSBoundParameters.ContainsKey('Scope')) { New-Object LocalPsModule($Name, $Scope, $version) ; break }
      $($PSBoundParameters.ContainsKey('version') -and !$PSBoundParameters.ContainsKey('Scope')) { New-Object LocalPsModule($Name, 'LocalMachine', $version) ; break }
      $(!$PSBoundParameters.ContainsKey('version') -and $PSBoundParameters.ContainsKey('Scope')) { New-Object LocalPsModule($Name, $Scope, $version) ; break }
      $(!$PSBoundParameters.ContainsKey('version') -and !$PSBoundParameters.ContainsKey('Scope')) { New-Object LocalPsModule($Name) ; break }
      Default { New-Object LocalPsModule($Name) }
    }
  }
  end {
    return $PsModule
  }
}