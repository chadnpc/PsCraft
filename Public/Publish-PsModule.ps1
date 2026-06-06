function Publish-PsModule {
  # .SYNOPSIS
  #   Publish PsModule To Local or Remote Repo
  # .DESCRIPTION
  #   A longer description of the function, its purpose, common use cases, etc.
  # .NOTES
  #   Inspired by the module: https://github.com/gaelcolas/Sampler
  # .LINK
  #   Specify a URI to a help page, this will show when Get-Help -Online is used.
  # .EXAMPLE
  #   Publish-PsModule -Verbose
  #   Explanation of the function or its result. You can include multiple examples with additional .EXAMPLE lines
  [CmdletBinding(SupportsShouldProcess)]
  param (
    # Parameter help description
    [Parameter(Position = 0, ParameterSetName = 'ByName')]
    [Alias('ModuleName')]
    [string]$Name,

    [Parameter(Position = 1, ParameterSetName = '__AllParameterSets')]
    [string]$ModulePath,

    [Parameter(Position = 2, ParameterSetName = '__AllParameterSets')]
    [Alias('repoDir')]
    [string]$RepoPath
  )

  process {
    $Module = [PsModule]::Create($Name, $ModulePath)
    if ($PSCmdlet.ShouldProcess('', '', "Publishing")) {
      $Module.Publish()
    }
  }

  end {
    return $Module
  }
}