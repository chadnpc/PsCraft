function New-Directory {
  [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'str')]
  param (
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'str')]
    [ValidateNotNullOrEmpty()][string]$Path,
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'dir')]
    [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$Dir
  )
  $nF = @(); $p = if ($PSCmdlet.ParameterSetName.Equals('str')) { [IO.DirectoryInfo]::New($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)) } else { $Dir }
  if ($PSCmdlet.ShouldProcess("Creating Directory '$($p.FullName)' ...", '', '')) {
    while (!$p.Exists) { $nF += $p; $p = $p.Parent }
    [Array]::Reverse($nF); $nF | ForEach-Object { $_.Create() }
  }
}