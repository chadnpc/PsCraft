function Get-ModulePath {
  # .DESCRIPTION
  #  Gets the path of installed modul; a path you can use with Import-module.
  # .EXAMPLE
  # Get-ModulePath -Name posh-git -version 0.7.3 | Import-module -verbose
  # Will retrieve posh-git version 0.7.3 from $env:PSModulePath and import it.
  [CmdletBinding()][OutputType([string])]
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter(Mandatory = $false, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        if (!($_ -as 'version' -is [version])) {
          throw [System.ArgumentException]::New('Please Provide a valid version string')
        }; $true
      }
    )]
    [string]$version,

    [Parameter(Mandatory = $false, Position = 2)]
    [ValidateSet('LocalMachine', 'CurrentUser')]
    [string]$Scope = 'LocalMachine'
  )
  if ($PSBoundParameters.ContainsKey('version')) {
    return (Find-InstalledModule -Name $Name -Version ([version]::New($version)) -Scope $Scope).Path
  } else {
    return (Find-InstalledModule -Name $Name -Scope $Scope).Path
  }
}