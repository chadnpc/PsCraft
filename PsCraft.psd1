#
# Module manifest for module 'PsCraft'
#
# Generated by: Alain Herve
#
# Generated on: 11/22/2024
#

@{
  # Script module or binary module file associated with this manifest.
  RootModule        = 'PsCraft.psm1'
  ModuleVersion     = '<ModuleVersion>'

  # Supported PSEditions
  # CompatiblePSEditions = @()

  # ID used to uniquely identify this module
  GUID              = 'd11c6332-4c7b-460c-ba17-63b9c12e49fd'
  Author            = 'Alain Herve'
  CompanyName       = 'chadnpc'
  Copyright         = 'Copyright © <Year> Alain Herve. All rights reserved.'
  Description       = "Provides cmdlets to speed up common PowerShell development tasks."
  PowerShellVersion = '3.0'

  # Name of the Windows PowerShell host required by this module
  # PowerShellHostName = ''
  # Minimum version of the Windows PowerShell host required by this module
  # PowerShellHostVersion = ''
  # Minimum version of Microsoft .NET Framework required by this module. This prerequisite is valid for the PowerShell Desktop edition only.
  # DotNetFrameworkVersion = ''
  # Minimum version of the common language runtime (CLR) required by this module. This prerequisite is valid for the PowerShell Desktop edition only.
  CLRVersion        = '2.0.50727'
  # Processor architecture (None, X86, Amd64) required by this module
  # ProcessorArchitecture = ''
  # Modules that must be imported into the global environment prior to importing this module
  RequiredModules   = @(
    "PSScriptAnalyzer",
    "Pester",
    "psake"
  )
  # Assemblies that must be loaded prior to importing this module
  # RequiredAssemblies = @()

  # Script files (.ps1) that are run in the caller's environment prior to importing this module.
  # ScriptsToProcess = @()

  # Type files (.ps1xml) to be loaded when importing this module
  # TypesToProcess = @()

  # Format files (.ps1xml) to be loaded when importing this module
  # FormatsToProcess = @()

  # Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
  # NestedModules = @()

  # Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
  # FunctionsToExport = '*'

  # Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no cmdlets to export.
  CmdletsToExport   = '*'

  # Variables to export from this module
  VariablesToExport = '*'

  # Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export.
  AliasesToExport   = '*'

  # DSC resources to export from this module
  # DscResourcesToExport = @()

  # List of all modules packaged with this module
  # ModuleList = @()

  # List of all files packaged with this module
  # FileList = @()

  # Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
  PrivateData       = @{
    PSData = @{
      Tags                       = @('powershell', 'scriptmodule', 'psake')
      LicenseUri                 = 'https://alain.MIT-license.org'
      ProjectUri                 = 'https://github.com/chadnpc/PsCraft'
      IconUri                    = 'https://github.com/user-attachments/assets/0584a9ee-99a2-4b4b-bfa8-47285f0abdde'
      ExternalModuleDependencies = @("cliHelper.env")
      ReleaseNotes               = "
<ReleaseNotes>
"
    } # End of PSData hashtable
  } # End of PrivateData hashtable

  # HelpInfo URI of this module
  # HelpInfoURI = ''

  # Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
  # DefaultCommandPrefix = ''
}

