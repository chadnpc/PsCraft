function Write-BuildLog {
  [CmdletBinding()]
  param(
    [parameter(Mandatory, Position = 0, ValueFromRemainingArguments, ValueFromPipeline)]
    [System.Object]$Message,

    [parameter()]
    [Alias('c', 'Command')]
    [Switch]$Cmd,

    [parameter()]
    [Alias('w')]
    [Switch]$Warning,

    [parameter()]
    [Alias('s', 'e')]
    [Switch]$Severe,

    [parameter()]
    [Alias('x', 'nd', 'n')]
    [Switch]$Clean
  )
  Begin {
    ($f, $l) = switch ($true) {
      $($PSBoundParameters.ContainsKey('Debug') -and $PSBoundParameters['Debug'] -eq $true) { 'Yellow', '##[debug]   '; break }
      $($PSBoundParameters.ContainsKey('Verbose') -and $PSBoundParameters['Verbose'] -eq $true) { $(if ($Host.UI.RawUI.ForegroundColor -eq 'Gray') { 'White' } else { 'Gray' }), '##[Verbose] '; break }
      $Severe { 'Red', '##[Error]   '; break }
      $Warning { 'Yellow', '##[Warning] '; break }
      $Cmd { 'Magenta', '##[Command] '; break }
      Default {
        $(if ($Host.UI.RawUI.ForegroundColor -eq 'Gray') { 'White' } else { 'Gray' }), '##[Info]    '
      }
    }
  }
  Process {
    $fmtMsg = if ($Clean) {
      $Message -split "[\r\n]" | Where-Object { $_ } | ForEach-Object {
        $l + $_
      }
    } else {
      $date = "$(Get-Elapsed) "
      if ($Cmd) {
        $i = 0
        $Message -split "[\r\n]" | Where-Object { $_ } | ForEach-Object {
          $tag = if ($i -eq 0) {
            'PS > '
          } else {
            '  >> '
          }
          $l + $date + $tag + $_
          $i++
        }
      } else {
        $Message -split "[\r\n]" | Where-Object { $_ } | ForEach-Object {
          $l + $date + $_
        }
      }
    }
    Write-Host -f $f $($fmtMsg -join "`n")
  }
}