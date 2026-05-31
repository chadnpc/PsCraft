#!/usr/bin/env pwsh
using namespace System.IO
using namespace System.Collections.Generic
using namespace System.Collections.ObjectModel

# .SYNOPSIS
#   PsCraft testScript v0.3.1
# .EXAMPLE
#   .\Test-Module.ps1 -version 0.3.1
#   Will test the module in ./BuildOutput/PsCraft/0.3.1/
# .EXAMPLE
#   .\Test-Module.ps1
#   Will test the latest module version in ./BuildOutput/PsCraft/
# .EXAMPLE
#   Import-Module .\PsCraft.psd1 -Verbose -Force; .\Test-Module.ps1 -NoBuild
#   Will test the current source code of the module but without building it
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
        throw [InvalidDataException]::New('Please Provide a valid version')
      }
    }
  )][ArgumentCompleter({
      [OutputType([System.Management.Automation.CompletionResult])]
      param([string]$CommandName, [string]$ParameterName, [string]$WordToComplete, [System.Management.Automation.Language.CommandAst]$CommandAst, [System.Collections.IDictionary]$FakeBoundParameters)
      $CompletionResults = [List[System.Management.Automation.CompletionResult]]::new()
      $b_Path = [IO.Path]::Combine($PSScriptRoot, 'BuildOutput', 'PsCraft')
      if ((Test-Path -Path $b_Path -PathType Container -ErrorAction Ignore)) {
        [IO.DirectoryInfo]::New($b_Path).GetDirectories().Name | Where-Object { $_ -like "*$wordToComplete*" -and $_ -as 'version' -is 'version' } | ForEach-Object { [void]$CompletionResults.Add([System.Management.Automation.CompletionResult]::new($_, $_, "ParameterValue", $_)) }
      }
      return $CompletionResults
    }
  )]
  [string]$version,

  [Alias('NoBuild')]
  [switch]$SkipBuildOutput,
  [switch]$CleanUp
)
begin {
  #requires -Version 7
  $TestResults = $null;
  $BuildOutDir = $PSScriptRoot
  $BuildOutput = [IO.DirectoryInfo]::New([IO.Path]::Combine($PSScriptRoot, 'BuildOutput', 'PsCraft'))
  if (!$BuildOutput.Exists -and !$SkipBuildOutput) {
    Write-Warning "NO_Build_OutPut | Please make sure to Build the module successfully first before running Test-Module.ps1 or use -SkipBuildOutput switch to skip this check"
    throw [DirectoryNotFoundException]::New("Cannot find path '$($BuildOutput.FullName)' because it does not exist.")
  }
  if ($BuildOutput.Exists) {
    # Get latest built version
    if ([string]::IsNullOrWhiteSpace($version)) {
      $version = $BuildOutput.GetDirectories().Name -as 'version[]' | Select-Object -Last 1
    }
    $BuildOutDir = Resolve-Path $([IO.Path]::Combine($PSScriptRoot, 'BuildOutput', 'PsCraft', $version)) -ErrorAction Ignore | Get-Item -ErrorAction Ignore
    if (![IO.Directory]::Exists("$BuildOutDir")) { throw [DirectoryNotFoundException]::New($BuildOutDir) }
  }
  $manifestFile = [IO.FileInfo]::New([IO.Path]::Combine($BuildOutDir, "PsCraft.psd1"))
}

process {
  Write-Host "==========================================" -ForegroundColor Cyan
  Write-Host "  PsCraft Module - Test Suite" -ForegroundColor Cyan
  Write-Host "==========================================" -ForegroundColor Cyan
  Write-Host "[0/3] Checking Prerequisites ..." -ForegroundColor Green
  if (![IO.Directory]::Exists("$BuildOutDir")) {
    $msg = "Directory '$BuildOutDir' Not Found."
    if ($SkipBuildOutput) { Write-Warning $msg }
    else { throw [DirectoryNotFoundException]::New($msg) }
  }
  if (!$manifestFile.Exists) {
    throw [FileNotFoundException]::New("Could Not Find Module manifest File '$manifestFile'")
  }
  if (!(Test-Path -Path $([IO.Path]::Combine($PSScriptRoot, "PsCraft.psd1")) -PathType Leaf -ErrorAction Ignore)) { throw [FileNotFoundException]::New("Module manifest file Was not Found in '$BuildOutDir'.") }
  $script:fnNames = [List[string]]::New(); $testFiles = [List[IO.FileInfo]]::New()
  [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', 'PsCraft.Integration.Tests.ps1')))
  [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', 'PsCraft.Features.Tests.ps1')))
  [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', 'PsCraft.Module.Tests.ps1')))
  $missingTestFiles = $testFiles.Where({ !$_.Exists })
  if ($missingTestFiles.count -gt 0) { throw [FileNotFoundException]::new("One or more missing TestFiles! $($testFiles.BaseName -join ', ')") }

  # Load environment variables from .env file
  $v = $VerbosePreference; $VerbosePreference = "Continue"; Read-Env ([IO.Path]::Combine($PSScriptRoot, ".env")) | Set-Env; $VerbosePreference = $v;
  Write-Host "[1/2] Testing ModuleManifest ..." -ForegroundColor Green
  if (!$SkipBuildOutput) {
    Test-ModuleManifest -Path $manifestFile.FullName -ErrorAction Stop -Verbose:$false
  }
  Write-Host "[2/2] Running all test files ..." -ForegroundColor Green
  $IsCorrectPesterVersion = (Get-Module Pester -ListAvailable | Select-Object -Expand Version) -le [version]"3.4.0"
  if (!$IsCorrectPesterVersion) {
    throw "Pester tests were writen on pester v3.4.0, please downgrade and try again"
  }
  $TestResults = Invoke-Pester -Path $([IO.Path]::Combine($PSScriptRoot, 'Tests')) -OutputFile ([IO.Path]::Combine("$TestsPath", "results.xml")) -OutputFormat NUnitXml -PassThru
}

end {
  return $TestResults
}
