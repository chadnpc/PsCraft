function Remove-InvisibleChars {
  <#
    .SYNOPSIS
    Removes invisible characters from all files in the current directory and subdirectories.

    .NOTES
    - Written by chatgpt for Linux.
    - Requires `sed` or appropriate substitution tool.
    #>
  [CmdletBinding(SupportsShouldProcess = $true)]
  param (
    [string[]]$chars = @(
      "`x00", # Null
      "`x01", # Start of Header
      "`x02", # Start of Text
      "`x03", # End of Text
      "`x09", # Horizontal Tab
      "`x0B", # Vertical Tab
      "`x0C"  # Form Feed
    )
  )
  process {
    # Retrieve all files recursively
    $files = Get-ChildItem -File -Recurse -Force

    foreach ($file in $files) {
      Write-Verbose "Processing file: $($file.FullName)"

      # Read content of the file
      $content = Get-Content -Raw -Path $file.FullName

      # Remove invisible characters
      foreach ($char in $chars) {
        $charValue = [char][byte]($char -replace '`x', '0x')
        $content = $content -replace [regex]::Escape($charValue), ''
      }

      # Save the cleaned content back to the file
      $cleanFilePath = [System.IO.Path]::Combine($file.DirectoryName, "$($file.BaseName)_clean$($file.Extension)")
      Set-Content -Path $cleanFilePath -Value $content
    }

    # Optionally delete old files and rename cleaned files
    foreach ($file in $files) {
      $cleanFilePath = [System.IO.Path]::Combine($file.DirectoryName, "$($file.BaseName)_clean$($file.Extension)")
      if (Test-Path $cleanFilePath) {
        Remove-Item -Path $file.FullName -Verbose
        Rename-Item -Path $cleanFilePath -NewName $file.Name -Verbose
      }
    }
  }
}