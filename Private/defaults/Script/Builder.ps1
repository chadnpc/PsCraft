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