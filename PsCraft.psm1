#!/usr/bin/env pwsh
using namespace System.IO
using namespace System.ComponentModel
using namespace System.Collections.Generic
using namespace System.Collections.ObjectModel
using namespace System.Management.Automation.Language

#Requires -Modules PsModuleBase, PsCraft
#Requires -Psedition Core

using module Private\BuildLog.psm1
using module Private\Enums.psm1
using module Private\Models.psm1
using module Private\ModuleManager.psm1
using module Private\PsModule.psm1
using module Private\PsModuleData.psm1

# .SYNOPSIS
#  PsCraft: the module builder and manager.
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

$global:OutputEncoding = [console]::InputEncoding = [console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# Types that will be available to users when they import the module.
# Hint: To automatically update the typestoexport variable you can use:
# .\scripts\update_exporatable_types.ps1

$typestoExport = @(
  [BuildLog], [SaveOptions], [PSEdition], [ModuleItemAttribute], [ParseResult], [AliasVisitor], [ModuleManager], [PsModule], [PsModuleData], [PsCraft]
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

$scripts = @();
$Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += Get-ChildItem "$PSScriptRoot/Private" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += $Public

foreach ($file in $scripts) {
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
