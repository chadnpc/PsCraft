function Get-PSGalleryItems {
  <#
  .DESCRIPTION
    This script will save all versions of all scripts and modules published to the PowerShell Gallery by a given Author.
    The Author is specified in the manifest for each item, and is expected to be consistent for a given user.

  .Example
    $items = Get-PSGalleryItems -Author 'Alain Herve'
  .Example
    $null = Get-PSGalleryItems -Author 'Alain Herve' -OutFolder $env:HOME/my_psgallery_items

    This will find all items where 'Alain Herve' is listed as an author, and save them into $env:HOME/my_psgallery_items.
    The folder will be created if it does not exist.
  .LINK
    https://github.com/chadnpc/PsCraft/blob/main/Public/Get-PSGalleryItems.ps1
  #>
  [CmdletBinding()][OutputType([System.Collections.Generic.List[PSGalleryItem]])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrWhiteSpace()]
    [Alias('Author')]
    [string] $AuthorName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrWhiteSpace()]
    [string] $OutFolder
  )

  begin {
    #Requires -Modules cliHelper.core
    class PSGalleryItem {
      [string] $Name
      [version] $Version
      [string] $Path
      [string] $Repository
      PSGalleryItem() {}
      PSGalleryItem([hashtable]$map) {
        $map.Keys.ForEach({
            $this.$_ = $map[$_]
          }
        )
      }
    }
    class PSRepoItem {
      [string] $AdditionalMetadata
      [string] $Author
      [string] $CompanyName
      [string] $Copyright
      [Object[]] $Dependencies
      [string] $Description
      [string] $IconUri
      [hashtable] $Includes
      [object] $InstalledDate
      [uri] $LicenseUri
      [string] $Name
      [string] $PackageManagementProvider
      [version] $PowerShellGetFormatVersion
      [uri] $ProjectUri
      [object] $PublishedDate
      [string] $ReleaseNotes
      [string] $Repository
      [string] $RepositorySourceLocation
      [string[]] $Tags
      [string] $Type
      [object] $UpdatedDate
      [version] $Version
      PSRepoItem() {}
      PSRepoItem([Object]$Object) {
        if ($null -ne $Object) {
          $Object.PsObject.Properties.Name.ForEach({
              $this.$_ = $Object.$_
            }
          )
        }
      }
      [string] ToString() {
        return $this.Name
      }
    }
  }

  process {
    $Items = [System.Collections.Generic.List[PSGalleryItem]]::new(); $OutFolderExists = Test-Path -Path $OutFolder -ea Ignore
    if ($PSBoundParameters.ContainsKey('OutFolder')) {
      If (!$OutFolderExists) {
        Write-Console "Creating folder $OutFolder" -f LimeGreen
        New-Item $OutFolder -ItemType Directory
      }
    }
    $mSearch = [progressUtil]::WaitJob("[1/2] Retrieving all modules published by the author '$AuthorName'", { return Find-Module -Repository 'psgallery' })
    $Ps_repo = [PSRepoItem[]](Receive-Job $mSearch)
    $Modules = $Ps_repo.Where({ ($_.Author.count -eq 1) ? ($_.Author -eq $AuthorName) : ($_.Author -contains $AuthorName) })
    $Modules.ForEach({
        Write-Console "  Retrieving all versions of $($_.Name)" -f LimeGreen
        Find-Module -Name $_.Name -Repository psgallery -AllowPrerelease -AllVersions -Verbose:$false | ForEach-Object {
          $Items += [PSGalleryItem]@{
            Name       = $_.Name
            Version    = $_.Version
            Path       = $_.Path
            Repository = $_.Repository
          }
          if ($OutFolderExists) {
            Save-Module -Name $_.Name -RequiredVersion $_.Version -Path $OutFolder -Repository psgallery -AllowPrerelease
          }
        }
      }
    )
    $sSearch = [progressUtil]::WaitJob("[2/2] Retrieving all scripts published by the author '$AuthorName'", { return Find-Script -Repository 'psgallery' })
    $Ps_repo = [PSRepoItem[]](Receive-Job $sSearch)
    $Scripts = $Ps_repo.Where({ ($_.Author.count -eq 1) ? ($_.Author -eq $AuthorName) : ($_.Author -contains $AuthorName) })
    $Scripts.ForEach({
        Write-Console "  Retrieving all versions of $($_.Name)" -f LimeGreen
        Find-Script -Name $_.Name -Repository psgallery -AllowPrerelease -AllVersions -Verbose:$false | ForEach-Object {
          $Items += [PSGalleryItem]@{
            Name       = $_.Name
            Version    = $_.Version
            Path       = $_.Path
            Repository = $_.Repository
          }
          if ($OutFolderExists) {
            Save-Script -Name $_.Name -RequiredVersion $_.Version -Path $OutFolder -Repository psgallery -AllowPrerelease
          }
        }
      }
    )
  }

  end {
    return $Items
  }
}
