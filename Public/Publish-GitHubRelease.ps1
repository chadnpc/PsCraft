function Publish-GitHubRelease {
  # .SYNOPSIS
  #   Publishes a release to GitHub Releases.
  [CmdletBinding()]
  Param (
    [parameter(Mandatory = $true)]
    [String]$VersionNumber,

    [parameter(Mandatory = $false)]
    [String]$CommitId = 'main',

    [parameter(Mandatory = $true)]
    [String]$ReleaseNotes,

    [parameter(Mandatory = $true)]
    [ValidateScript( { Test-Path $_ })]
    [String]$ArtifactPath,

    [parameter(Mandatory = $true)]
    [String]$GitHubUsername,

    [parameter(Mandatory = $true)]
    [String]$GitHubRepository,

    [parameter(Mandatory = $true)]
    [String]$GitHubApiKey,

    [parameter(Mandatory = $false)]
    [Switch]$PreRelease,

    [parameter(Mandatory = $false)]
    [Switch]$Draft
  )
  $releaseData = @{
    tag_name         = [string]::Format("v{0}", $VersionNumber)
    target_commitish = $CommitId
    name             = [string]::Format("$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))) v{0}", $VersionNumber)
    body             = $ReleaseNotes
    draft            = [bool]$Draft
    prerelease       = [bool]$PreRelease
  }

  $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($gitHubApiKey + ":x-oauth-basic"))

  $releaseParams = @{
    Uri         = "https://api.github.com/repos/$GitHubUsername/$GitHubRepository/releases"
    Method      = 'POST'
    Headers     = @{
      Authorization = $auth
    }
    ContentType = 'application/json'
    Body        = (ConvertTo-Json $releaseData -Compress)
  }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $result = Invoke-RestMethod @releaseParams
  $uploadUri = $result | Select-Object -ExpandProperty upload_url
  $uploadUri = $uploadUri -creplace '\{\?name,label\}'
  $artifact = Get-Item $ArtifactPath
  $uploadUri = $uploadUri + "?name=$($artifact.Name)"
  $uploadFile = $artifact.FullName

  $uploadParams = @{
    Uri         = $uploadUri
    Method      = 'POST'
    Headers     = @{
      Authorization = $auth
    }
    ContentType = 'application/zip'
    InFile      = $uploadFile
  }
  $result = Invoke-RestMethod @uploadParams
}