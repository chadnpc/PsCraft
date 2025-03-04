function New-PsModule {
  # .SYNOPSIS
  #   Creates a PsModule Object, that can be saved to the disk.
  # .DESCRIPTION
  #   New-Module serves two ways of creating modules, but in either case, it can generate the psd1 and psm1 necessary for a module based on script files.
  #   In one use case, its just a simplified wrapper for New-ModuleManifest which answers some of the parameters based on the files already in the module folder.
  #   In the second use case, it allows you to collect one or more scripts and put them into a new module folder.
  # .LINK
  #   https://github.com/chadnpc/PsCraft/blob/main/Public/ModuleManager/New-PSModule.ps1
  # .EXAMPLE
  #   $m = New-PsModule
  #   This example shows how to create a random module.
  # .Example
  #   Get-ChildItem *.ps1, *.psd1 -Recurse | New-PsModule MyUtility
  #   This example shows how to pipe the files into the New-PsModule, and yet another approach to collecting the files needed. [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium", DefaultParameterSetName = "NewModuleManifest")]
  # .OUTPUTS
  #   [PsModule]
  [CmdletBinding(SupportsShouldProcess, DefaultParametersetName = 'ByName')]
  [OutputType([PsModule])]
  param (
    # The Name Of your Module; note that it Should always match BaseName of its path.
    [Parameter(Position = 0, ParameterSetName = 'ByName')]
    [ValidateScript({ if ($_ -match "[$([regex]::Escape(([IO.Path]::GetInvalidFileNameChars() -join '')))]") { throw "The ModuleName must be a valid folder name. The character '$($matches[0])' is not valid in a Module name." } else { $true } })]
    [string]$Name = (cliHelper.core\New-RandomFileName).Replace('.', ''),

    # The FullPath Of your Module.
    [Parameter(Position = 1, Mandatory = $false, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = '__AllParameterSets')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = '.',

    [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
    # The name of the author to use for the psd1 and copyright statement
    [PSDefaultValue(Help = { "ie: env:UserName" })]
    [String]$Author = ([moduleManager]::GetAuthorName()),

    [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
    [PSDefaultValue(Help = { "'A collection of script files by UserName (uses the value from the Author parmeter)" })]
    [string]${Description} = "A collection of script files by $Author",

    [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
    [PSDefaultValue(Help = "1.0 (when -Upgrade is set, increments the existing value to the nearest major version number)")]
    [Alias("Version", "MV")][Version]
    ${ModuleVersion} = "0.1.0",

    [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
    [AllowEmptyString()][String]
    $CompanyName = "None (Personal Module)",

    [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
    [PSDefaultValue(help = { "Your current CLRVersion number (rounded): ($PSVersionTable.CLRVersion)" })][version]
    ${ClrVersion} = $PSVersionTable.CLRVersion,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
    [PSDefaultValue(Help = { "Your current PSVersion number (rounded): ($($PSVersionTable.PSVersion.ToString(2))" })]
    [version][Alias("PSV")]
    ${PowerShellVersion} = ("{0:F1}" -f [double]($PSVersionTable.PSVersion | Select-Object @{l = 'str'; e = { $_.Major.ToString() + '.' + $_.Minor.ToString() } }).str),

    # Specifies modules that this module requires. (This is a passthru for New-ModuleManifest)
    [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
    [System.Object[]][Alias("Modules", "RM")]
    ${RequiredModules} = $null,

    # Specifies the assembly (.dll) files that the module requires. (This is a passthru for New-ModuleManifest)
    [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
    [string[]][Alias("Assemblies", "RA")][AllowEmptyCollection()]
    ${RequiredAssemblies} = $null,

    [Parameter(Position = 0, ParameterSetName = 'ByConfig')]
    [ValidateNotNullOrEmpty()]
    [Array]$Configuration
  )

  begin {
    $Module = $null; $Path = [PsCraft]::GetResolvedPath($Path)
    #Requires -RunAsAdministrator
  }

  process {
    Write-Console "Creating Module $Name ..." -f SlateBlue # Todo: Add loading animation
    if ($PSCmdlet.MyInvocation.BoundParameters.ContainsKey("Path")) {
      $Module = [PsModule]::Create($Name, $path)
    } else {
      $Module = [PsModule]::Create($Name)
    }
    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
      @(
        "Author",
        "ClrVersion",
        "Description",
        "CompanyName",
        "ModuleVersion",
        "RequiredModules",
        "PowerShellVersion",
        "RequiredAssemblies"
      ).ForEach({
          $n = $_; $isBound = $PSCmdlet.MyInvocation.BoundParameters.ContainsKey($n)
          $value = if ($isBound) { $PSCmdlet.MyInvocation.BoundParameters[$n] } else { Get-Variable -Name $n -ValueOnly }
          # Write-Verbose "$n = $value $(if(!$isBound){'(default)'})"
          if ($null -ne $value) { $Module.Set($_, $value) }
        }
      )
    } else {
      # TODO: Add support for ByConfig
      # $Module.Data = [PsModule]::CreateModuleData($configuration)
      throw "Config params r not yet supported (WIP)"
    }
    if ($PSCmdlet.ShouldProcess("", "", "Format and Write Module folder structure")) {
      [void]$Module.save(); $_p = $Module.Path.FullName
      if ([IO.Directory]::Exists($_p)) {
        ([bool](Get-Command tree -CommandType Application -ea Ignore) ? ([string]::Join([char]10, (tree $_p | Out-String)) | cliHelper.core\Write-Console -f SlateBlue) : (cliHelper.core\Show-Tree $_p -Depth 5)) | Out-Host
      }
    }
  }

  end {
    return $Module
  }
}