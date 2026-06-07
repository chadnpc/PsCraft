$jobs = [BackgroundJob[]]@()
foreach ($filePath in $FilePaths) {
        $fileName = [IO.Path]::GetFileName($filePath)
        $jobs += @{
          n = "[yellow]Copy $fileName[/]"
          s = { param($f, $d) Copy-Item -Path $f -Destination $d -Force -ErrorAction Ignore }
          a = $filePath, $DestinationPath
        }
      }
      $results = [ThreadRunner]::Run("Copying Module Files", $jobs, $FilePaths.Count, "Modern")
      $results | Out-String | Write-Host