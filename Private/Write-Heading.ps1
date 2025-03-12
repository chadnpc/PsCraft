function Write-Heading {
  param(
    [parameter(Position = 0, Mandatory = $true)]
    [ValidateNotNullOrWhiteSpace()]
    [String]$Title,

    [parameter(Position = 1)]
    [Switch]$Passthru
  )
  process {
    $msgList = @(
      ''
      "##[section] $(Get-Elapsed) $Title"
    ) -join "`n"
    if ($Passthru) {
      $msgList
    } else {
      $msgList | Write-Host -f Green
    }
  }
}