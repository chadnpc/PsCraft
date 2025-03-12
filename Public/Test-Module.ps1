function Test-Module {
  # .SYNOPSIS
  #     Run Tests
  # .EXAMPLE
  #     Test-Module -version 0.1.0
  #     Will test the module in .\BuildOutput\<ModuleName>\0.1.0\
  # .EXAMPLE
  #     Test-Module
  #     Will test the latest  module version in .\BuildOutput\<ModuleName>\
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $false, Position = 0)]
    [Alias('Module')][string]$ModulePath = $PSScriptRoot,

    # Path Containing Tests
    [Parameter(Mandatory = $false, Position = 1)]
    [Alias('Tests')][string]$TestsPath = [IO.Path]::Combine($PSScriptRoot, 'Tests'),

    # Version string
    [Parameter(Mandatory = $false, Position = 2)]
    [ValidateScript({ if (($_ -as 'version') -is [version]) { return $true } else { throw [System.IO.InvalidDataException]::New('Please Provide a valid version') } })]
    [ArgumentCompleter({
        [OutputType([System.Management.Automation.CompletionResult])]
        param([string]$CommandName, [string]$ParameterName, [string]$WordToComplete, [System.Management.Automation.Language.CommandAst]$CommandAst, [System.Collections.IDictionary]$FakeBoundParameters)
        $CompletionResults = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $b_Path = [IO.Path]::Combine($PSScriptRoot, 'BuildOutput', (Get-Item $PSScriptRoot).Name)
        if ((Test-Path -Path $b_Path -PathType Container -ErrorAction Ignore)) {
          [IO.DirectoryInfo]::New($b_Path).GetDirectories().Name | Where-Object { $_ -like "*$wordToComplete*" -and $_ -as 'version' -is 'version' } | ForEach-Object { [void]$CompletionResults.Add([System.Management.Automation.CompletionResult]::new($_, $_, "ParameterValue", $_)) }
        }
        return $CompletionResults
      })]
    [string]$version,
    [switch]$CleanUp
  )

  process {
    # return $builder.TestModule()
  }
}