function Test-PsModuleSchema {
  # .EXAMPLE
  # $Report = Test-PsModuleSchema -Schema $ModuleSchema -ModuleName "MyAwesomeModule"
  # if (-not $Report.IsValid) {
  #   Write-Error "Project template does not match the schema guidelines!"
  #   # Display failing components cleanly in a grid layout or list
  #   $Report.Details | Where-Object Status -EQ 'FAIL' | Format-Table -AutoSize
  # } else {
  #   Write-Host "Project directory conforms perfectly to structural constraints." -ForegroundColor Green
  # }
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [PsModuleSchema]$Schema,

    [Parameter(Mandatory = $true)]
    [string]$ModuleName
  )

  process {
    $validationResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $allValid = $true

    # Validate Folders
    foreach ($folderNode in $Schema.Folders) {
      $targetPath = $folderNode.ResolvePath($ModuleName)
      $exists = Test-Path -Path $targetPath -PathType Container

      if ($folderNode.IsRequired -and -not $exists) { $allValid = $false }

      $validationResults.Add([PSCustomObject]@{
          Type     = 'Folder'
          Key      = $folderNode.Key
          Expected = $targetPath
          Exists   = $exists
          Status   = if ($exists) { 'PASS' } else { if ($folderNode.IsRequired) { 'FAIL' } else { 'OPTIONAL_MISSING' } }
        })
    }

    # Validate Files
    foreach ($fileNode in $Schema.Files) {
      $targetPath = $fileNode.ResolvePath($ModuleName)
      $exists = Test-Path -Path $targetPath -PathType Leaf

      if ($fileNode.IsRequired -and -not $exists) { $allValid = $false }

      $validationResults.Add([PSCustomObject]@{
          Type     = 'File'
          Key      = $fileNode.Key
          Expected = $targetPath
          Exists   = $exists
          Status   = if ($exists) { 'PASS' } else { if ($fileNode.IsRequired) { 'FAIL' } else { 'OPTIONAL_MISSING' } }
        })
    }

    # Return a rich object wrapper containing both the global state and fine-grained data
    return [PSCustomObject]@{
      IsValid = $allValid
      Details = $validationResults
    }
  }
}
