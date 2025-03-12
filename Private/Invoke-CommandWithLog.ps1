function Invoke-CommandWithLog {
  [CmdletBinding()]
  Param (
    [parameter(Mandatory, Position = 0)]
    [ScriptBlock]$ScriptBlock
  )
  Write-BuildLog -Command ($ScriptBlock.ToString() -join "`n");
  $ScriptBlock.Invoke()
}