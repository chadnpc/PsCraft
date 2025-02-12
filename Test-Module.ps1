using namespace System
using namespace System.IO
using namespace System.Management.Automation
<#
.SYNOPSIS
    Run Tests
.EXAMPLE
    .\Test-Module.ps1 -version 0.2.7
    Will test the module in .\BuildOutput\PsCraft\0.2.7\
.EXAMPLE
    .\Test-Module.ps1
    Will test the latest  module version in .\BuildOutput\PsCraft\
#>
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
        throw [System.IO.InvalidDataException]::New('Please Provide a valid version')
      }
    }
  )][ArgumentCompleter({
      [OutputType([System.Management.Automation.CompletionResult])]
      param([string]$CommandName, [string]$ParameterName, [string]$WordToComplete, [System.Management.Automation.Language.CommandAst]$CommandAst, [System.Collections.IDictionary]$FakeBoundParameters)
      $CompletionResults = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
      $b_Path = [IO.Path]::Combine($PSScriptRoot, 'BuildOutput', 'PsCraft')
      if ((Test-Path -Path $b_Path -PathType Container -ErrorAction Ignore)) {
        [IO.DirectoryInfo]::New($b_Path).GetDirectories().Name | Where-Object { $_ -like "*$wordToComplete*" -and $_ -as 'version' -is 'version' } | ForEach-Object { [void]$CompletionResults.Add([System.Management.Automation.CompletionResult]::new($_, $_, "ParameterValue", $_)) }
      }
      return $CompletionResults
    }
  )]
  [string]$version,
  [switch]$skipBuildOutputTest,
  [switch]$CleanUp
)
begin {
  $TestResults = $null
  $BuildOutput = [IO.DirectoryInfo]::New([IO.Path]::Combine($PSScriptRoot, 'BuildOutput', 'PsCraft'))
  if (!$BuildOutput.Exists) {
    Write-Warning "NO_Build_OutPut | Please make sure to Build the module successfully before running tests..";
    throw [System.IO.DirectoryNotFoundException]::new("Cannot find path '$($BuildOutput.FullName)' because it does not exist.")
  }
  # Get latest built version
  if ([string]::IsNullOrWhiteSpace($version)) {
    $version = $BuildOutput.GetDirectories().Name -as 'version[]' | Select-Object -Last 1
  }
  $BuildOutDir = Resolve-Path $([IO.Path]::Combine($PSScriptRoot, 'BuildOutput', 'PsCraft', $version)) -ErrorAction Ignore | Get-Item -ErrorAction Ignore
  if (!$BuildOutDir.Exists) { throw [System.IO.DirectoryNotFoundException]::new($BuildOutDir) }
  $manifestFile = [IO.FileInfo]::New([IO.Path]::Combine($BuildOutDir.FullName, "PsCraft.psd1"))
  Write-Host "[+] Checking Prerequisites ..." -ForegroundColor Green
  if (!$BuildOutDir.Exists) {
    $msg = 'Directory "{0}" Not Found. First make sure you successfuly built the module.' -f ([IO.Path]::GetRelativePath($PSScriptRoot, $BuildOutDir.FullName))
    if ($skipBuildOutputTest.IsPresent) {
      Write-Warning "$msg"
    } else {
      throw [System.IO.DirectoryNotFoundException]::New($msg)
    }
  }
  if (!$skipBuildOutputTest.IsPresent -and !$manifestFile.Exists) {
    throw [System.IO.FileNotFoundException]::New("Could Not Find Module manifest File $([IO.Path]::GetRelativePath($PSScriptRoot, $manifestFile.FullName))")
  }
  if (!(Test-Path -Path $([IO.Path]::Combine($PSScriptRoot, "PsCraft.psd1")) -PathType Leaf -ErrorAction Ignore)) { throw [System.IO.FileNotFoundException]::New("Module manifest file Was not Found in '$($BuildOutDir.FullName)'.") }
  $script:fnNames = [System.Collections.Generic.List[string]]::New(); $testFiles = [System.Collections.Generic.List[IO.FileInfo]]::New()
  [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', 'PsCraft.Integration.Tests.ps1')))
  [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', 'PsCraft.Features.Tests.ps1')))
  [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', 'PsCraft.Module.Tests.ps1')))
}

process {
  Get-Module PsCraft | Remove-Module -Force -Verbose:$false
  Write-Host "[+] Checking test files ..." -ForegroundColor Green
  $missingTestFiles = $testFiles.Where({ !$_.Exists })
  if ($missingTestFiles.count -gt 0) { throw [System.IO.FileNotFoundException]::new($($testFiles.BaseName -join ', ')) }
  Write-Host "[+] Testing ModuleManifest ..." -ForegroundColor Green
  if (!$skipBuildOutputTest.IsPresent) {
    Test-ModuleManifest -Path $manifestFile.FullName -ErrorAction Stop -Verbose
  }
  $PesterConfig = New-PesterConfiguration
  $PesterConfig.TestResult.OutputFormat = "NUnitXml"
  $PesterConfig.TestResult.OutputPath = [IO.Path]::Combine("$TestsPath", "results.xml")
  $PesterConfig.TestResult.Enabled = $True
  $TestResults = Invoke-Pester -Configuration $PesterConfig
}

end {
  return $TestResults
}
