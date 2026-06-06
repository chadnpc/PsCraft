#!/usr/bin/env pwsh
using namespace System.Management.Automation


#Requires -Psedition Core
#requires -Modules PsModuleBase, cliHelper.core, cliHelper.logger

using module .\Private\Enums.psm1
using module .\Private\BuildLog.psm1
using module .\Private\ModuleData.psm1
using module .\Private\Orchestrator.psm1

$global:OutputEncoding = [console]::InputEncoding = [console]::OutputEncoding = [System.Text.UTF8Encoding]::new()


# Types that will be available to users when they import the module.
# Hint: To automatically update the typestoexport variable you can use:
# .\scripts\update_exporatable_types.ps1

$typestoExport = @(
  [BuildLogEntry], [BuildTaskResult], [TestResult], [BuildLog], [BuildSummary], [SaveOptions], [PSEdition], [ModuleItemAttribute], [SchemaNode], [PsModuleSchema], [PsModuleDefaults], [PsModuleData], [AliasVisitor], [ParseResult], [BuildContext], [PsModule], [PsCraft], [BuildOrchestrator]
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

$cmdlets = @(); $Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$cmdlets += Get-ChildItem "$PSScriptRoot/Private/cmdlets" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$cmdlets += $Public

foreach ($file in $cmdlets) {
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
