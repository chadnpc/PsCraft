function Install-Dotnet {
  <#
  .SYNOPSIS
      Installs dotnet cli
  .DESCRIPTION
      Installs dotnet cli. If dotnet installation already exists in the given directory
      it will update it only if the requested version differs from the one already installed.

      Note that the intended use of this script is for Continuous Integration (CI) scenarios, where:
      - The SDK needs to be installed without user interaction and without admin rights.
      - The SDK installation doesn't need to persist across multiple CI runs.
      To set up a development environment or to run apps, use installers rather than this script. Visit https://dotnet.microsoft.com/download to get the installer.

  .PARAMETER Channel
      Default: LTS
      Download from the Channel specified. Possible values:
      - STS - the most recent Standard Term Support release
      - LTS - the most recent Long Term Support release
      - 2-part version in a format A.B - represents a specific release
            examples: 2.0, 1.0
      - 3-part version in a format A.B.Cxx - represents a specific SDK release
            examples: 5.0.1xx, 5.0.2xx
            Supported since 5.0 release
      Warning: Value "Current" is deprecated for the Channel parameter. Use "STS" instead.
      Note: The version parameter overrides the channel parameter when any version other than 'latest' is used.
  .PARAMETER Quality
      Download the latest build of specified quality in the channel. The possible values are: daily, preview, GA.
      Works only in combination with channel. Not applicable for STS and LTS channels and will be ignored if those channels are used.
      Supported since 5.0 release.
      Note: The version parameter overrides the channel parameter when any version other than 'latest' is used, and therefore overrides the quality.
  .PARAMETER Version
      Default: latest
      Represents a build version on specific channel. Possible values:
      - latest - the latest build on specific channel
      - 3-part version in a format A.B.C - represents specific version of build
            examples: 2.0.0-preview2-006120, 1.1.0
  .PARAMETER Internal
      Download internal builds. Requires providing credentials via -FeedCredential parameter.
  .PARAMETER FeedCredential
      Token to access Azure feed. Used as a query string to append to the Azure feed.
      This parameter typically is not specified.
  .PARAMETER InstallDir
      Default: %LocalAppData%\Microsoft\dotnet
      Path to where to install dotnet. Note that binaries will be placed directly in a given directory.
  .PARAMETER Architecture
      Default: <auto> - this value represents currently running OS architecture
      Architecture of dotnet binaries to be installed.
      Possible values are: <auto>, amd64, x64, x86, arm64, arm
  .PARAMETER SharedRuntime
      This parameter is obsolete and may be removed in a future version of this script.
      The recommended alternative is '-Runtime dotnet'.
      Installs just the shared runtime bits, not the entire SDK.
  .PARAMETER Runtime
      Installs just a shared runtime, not the entire SDK.
      Possible values:
          - dotnet     - the Microsoft.NETCore.App shared runtime
          - aspnetcore - the Microsoft.AspNetCore.App shared runtime
          - windowsdesktop - the Microsoft.WindowsDesktop.App shared runtime
  .PARAMETER DryRun
      If set it will not perform installation but instead display what command line to use to consistently install
      currently requested version of dotnet cli. In example if you specify version 'latest' it will display a link
      with specific version so that this command can be used deterministically in a build script.
      It also displays binaries location if you prefer to install or download it yourself.
  .PARAMETER NoPath
      By default this script will set environment variable PATH for the current process to the binaries folder inside installation folder.
      If set it will display binaries location but not set any environment variable.
  .PARAMETER Verbose
      Displays diagnostics information.
  .PARAMETER AzureFeed
      Default: https://builds.dotnet.microsoft.com/dotnet
      For internal use only.
      Allows using a different storage to download SDK archives from.
  .PARAMETER UncachedFeed
      For internal use only.
      Allows using a different storage to download SDK archives from.
  .PARAMETER ProxyAddress
      If set, the installer will use the proxy when making web requests
  .PARAMETER ProxyUseDefaultCredentials
      Default: false
      Use default credentials, when using proxy address.
  .PARAMETER ProxyBypassList
      If set with ProxyAddress, will provide the list of comma separated urls that will bypass the proxy
  .PARAMETER SkipNonVersionedFiles
      Default: false
      Skips installing non-versioned files if they already exist, such as dotnet.exe.
  .PARAMETER JSonFile
      Determines the SDK version from a user specified global.json file
      Note: global.json must have a value for 'SDK:Version'
  .PARAMETER DownloadTimeout
      Determines timeout duration in seconds for downloading of the SDK file
      Default: 1200 seconds (20 minutes)
  .PARAMETER KeepZip
      If set, downloaded file is kept
  .PARAMETER ZipPath
      Use that path to store installer, generated by default
  .EXAMPLE
      Install-Dotnet -Version 7.0.401
      Installs the .NET SDK version 7.0.401
  .EXAMPLE
      Install-Dotnet -Channel 8.0 -Quality GA
      Installs the latest GA (general availability) version of the .NET 8.0 SDK
  #>
  [CmdletBinding()]
  param (
    [string]$Channel = "LTS",
    [string]$Quality,
    [string]$Version = "Latest",
    [switch]$Internal,
    [string]$JSonFile,
    [Alias('i')][string]$InstallDir = "<auto>",
    [string]$Architecture = "<auto>",
    [string]$Runtime,
    [Obsolete("This parameter may be removed in a future version of this script. The recommended alternative is '-Runtime dotnet'.")]
    [switch]$SharedRuntime,
    [switch]$DryRun,
    [switch]$NoPath,
    [string]$AzureFeed,
    [string]$UncachedFeed,
    [string]$FeedCredential,
    [string]$ProxyAddress,
    [switch]$ProxyUseDefaultCredentials,
    [string[]]$ProxyBypassList = @(),
    [switch]$SkipNonVersionedFiles,
    [int]$DownloadTimeout = 1200,
    [switch]$KeepZip,
    [string]$ZipPath = [System.IO.Path]::combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName()),
    [switch]$Help
  )

  begin {
    Set-StrictMode -Version Latest
    $ogeap = $ErrorActionPreference
    $ogpap = $ProgressPreference
    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"

    if ($Help) {
      Get-Help $PSCommandPath -Examples
      exit
    }

    enum ArchitectureType { Auto; Amd64; X64; X86; Arm64; Arm }
    enum RuntimeProduct { DotNet; AspNetCore; WindowsDesktop; Sdk }

    class DotnetInstallException : System.Exception {
      DotnetInstallException([string]$message) : base($message) {}
      DotnetInstallException([string]$message, [System.Exception]$innerException) : base($message, $innerException) {}
    }

    class DownloadException : DotnetInstallException {
      [int]$StatusCode
      [string]$ErrorMessage

      DownloadException([string]$message, [int]$statusCode, [string]$errorMsg) : base($message) {
        $this.StatusCode = $statusCode
        $this.ErrorMessage = $errorMsg
      }
    }

    class Logger {
      static [void] Say([string]$str) {
        try { Write-Host "dotnet-install: $str" }
        catch { Write-Output "dotnet-install: $str" }
      }

      static [void] SayWarning([string]$str) {
        try { Write-Warning "dotnet-install: $str" }
        catch { Write-Output "dotnet-install: Warning: $str" }
      }

      static [void] SayError([string]$str) {
        try { $(Get-Variable Host).Value.UI.WriteErrorLine("dotnet-install: $str") }
        catch { Write-Output "dotnet-install: Error: $str" }
      }

      static [void] SayVerbose([string]$str) {
        try { Write-Verbose "dotnet-install: $str" }
        catch { Write-Output "dotnet-install: $str" }
      }

      static [void] MeasureAction([string]$name, [scriptblock]$block) {
        $time = Measure-Command $block
        [Logger]::SayVerbose("Action '$name' took $($time.TotalSeconds) seconds")
      }
    }

    class InstallContext {
      [string]$Channel
      [string]$Quality
      [string]$Version
      [bool]$Internal
      [string]$JSonFile
      [string]$InstallDir
      [string]$Architecture
      [string]$Runtime
      [bool]$SharedRuntime
      [bool]$DryRun
      [bool]$NoPath
      [string]$AzureFeed
      [string]$UncachedFeed
      [string]$FeedCredential
      [string]$ProxyAddress
      [bool]$ProxyUseDefaultCredentials
      [string[]]$ProxyBypassList
      [bool]$SkipNonVersionedFiles
      [int]$DownloadTimeout
      [bool]$KeepZip
      [string]$ZipPath
      [System.Management.Automation.InvocationInfo]$Invocation

      # Computed Values
      [string]$CLIArchitecture
      [string]$NormalizedQuality
      [string]$NormalizedChannel
      [string]$NormalizedProduct
      [string]$InstallRoot
      [string]$AssetName
      [string]$DotnetPackageRelativePath
      [string]$ScriptName = "Install-Dotnet.ps1"
    }

    class DownloadLinkInfo {
      [string]$DownloadLink
      [string]$SpecificVersion
      [string]$EffectiveVersion
      [string]$Type
    }

    class SystemUtils {
      static [void] LoadAssembly([string]$Assembly) {
        try { Add-Type -AssemblyName $Assembly | Out-Null } catch {
          $m = $_ | Format-List * -Force | Out-String
          Write-Host $m -f Red
        }
      }

      static [string] GetMachineArchitecture() {
        if ($null -ne $ENV:PROCESSOR_ARCHITEW6432) { return $ENV:PROCESSOR_ARCHITEW6432 }
        try {
          if (((Get-CimInstance -ClassName CIM_OperatingSystem).OSArchitecture) -like "ARM*") {
            if ([Environment]::Is64BitOperatingSystem) { return "arm64" }
            return "arm"
          }
        } catch {
          $m = $_ | Format-List * -Force | Out-String
          Write-Host $m -f Red
        }
        return $ENV:PROCESSOR_ARCHITECTURE
      }

      static [string] GetCLIArchitecture([string]$Architecture) {
        if ($Architecture -eq "<auto>") { $Architecture = [SystemUtils]::GetMachineArchitecture() }
        $a = switch ($Architecture.ToLowerInvariant()) {
          { $_ -in "amd64", "x64" } { "x64"; break }
          { $_ -eq "x86" } { "x86"; break }
          { $_ -eq "arm" } { "arm"; break }
          { $_ -eq "arm64" } { "arm64"; break }
          default { throw [DotnetInstallException]::new("Architecture '$Architecture' not supported.") }
        }
        return $a
      }

      static [string] GetAbsolutePath([string]$Path) {
        if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
        return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $Path))
      }

      static [void] PrependToPath([string]$InstallRoot, [bool]$NoPath) {
        $BinPath = [SystemUtils]::GetAbsolutePath([System.IO.Path]::Combine($InstallRoot, ""))
        if (-not $NoPath) {
          $SuffixedBinPath = "$BinPath;"
          if (-not $env:path.Contains($SuffixedBinPath)) {
            [Logger]::Say("Adding to current process PATH: `"$BinPath`". Note: This change will not be visible if PowerShell was run as a child process.")
            $env:path = $SuffixedBinPath + $env:path
          } else {
            [Logger]::SayVerbose("Current process PATH already contains `"$BinPath`"")
          }
        } else {
          [Logger]::Say("Binaries of dotnet can be found in $BinPath")
        }
      }
    }

    class HttpUtils {
      static [object] InvokeWithRetry([scriptblock]$ScriptBlock, [System.Threading.CancellationToken]$cancellationToken, [int]$MaxAttempts, [int]$SecondsBetweenAttempts, [int]$DownloadTimeout) {
        $Attempts = 0; $result = $null
        $startTime = Get-Date

        do {
          try {
            $result = & $ScriptBlock
          } catch {
            $Attempts++
            if (($Attempts -lt $MaxAttempts) -and -not $cancellationToken.IsCancellationRequested) {
              Start-Sleep -Seconds $SecondsBetweenAttempts
            } else {
              $elapsedTime = (Get-Date) - $startTime
              if (($elapsedTime.TotalSeconds - $DownloadTimeout) -gt 0 -and -not $cancellationToken.IsCancellationRequested) {
                throw [System.TimeoutException]::new("Failed to reach the server: connection timeout: default timeout is $DownloadTimeout second(s)", $_.Exception)
              }
              throw $_.Exception
            }
          }
        } while (($Attempts -lt $MaxAttempts) -and -not $cancellationToken.IsCancellationRequested)

        return $result
      }

      static [object] GetHttpResponse([Uri]$Uri, [bool]$HeaderOnly, [bool]$DisableRedirect, [bool]$DisableFeedCredential, [InstallContext]$Ctx) {
        $cts = [System.Threading.CancellationTokenSource]::new()

        $downloadScript = {
          $HttpClient = $null
          try {
            [SystemUtils]::LoadAssembly("System.Net.Http")

            $ProxyAddress = $Ctx.ProxyAddress
            $ProxyUseDefaultCredentials = $Ctx.ProxyUseDefaultCredentials
            if (-not $ProxyAddress) {
              try {
                $DefaultProxy = [System.Net.WebRequest]::DefaultWebProxy;
                if ($DefaultProxy -and (-not $DefaultProxy.IsBypassed($Uri))) {
                  if ($null -ne $DefaultProxy.GetProxy($Uri)) {
                    $ProxyAddress = $DefaultProxy.GetProxy($Uri).OriginalString
                  } else {
                    $ProxyAddress = $null
                  }
                  $ProxyUseDefaultCredentials = $true
                }
              } catch {
                $ProxyAddress = $null
                [Logger]::SayVerbose("Exception ignored: $_.Exception.Message - moving forward...")
              }
            }

            $HttpClientHandler = [System.Net.Http.HttpClientHandler]::new()
            if ($ProxyAddress) {
              $HttpClientHandler.Proxy = [System.Net.WebProxy]::new()
              $HttpClientHandler.Proxy.Address = $ProxyAddress
              $HttpClientHandler.Proxy.UseDefaultCredentials = $ProxyUseDefaultCredentials
              $HttpClientHandler.Proxy.BypassList = $Ctx.ProxyBypassList
            }
            if ($DisableRedirect) { $HttpClientHandler.AllowAutoRedirect = $false }

            $HttpClient = [System.Net.Http.HttpClient]::new($HttpClientHandler)
            $HttpClient.Timeout = [TimeSpan]::FromSeconds($Ctx.DownloadTimeout)

            $completionOption = $HeaderOnly ? [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead : [System.Net.Http.HttpCompletionOption]::ResponseContentRead
            $UriWithCredential = $DisableFeedCredential ? $Uri.ToString() : "$Uri$($Ctx.FeedCredential)"

            $Task = $HttpClient.GetAsync($UriWithCredential, $completionOption).ConfigureAwait($false)
            $Response = $Task.GetAwaiter().GetResult()

            if (($null -eq $Response) -or ((-not $HeaderOnly) -and (-not ($Response.IsSuccessStatusCode)))) {
              $StatusCode = if ($null -ne $Response) { [int]$Response.StatusCode } else { 0 }
              $ErrMsg = "Unable to download $Uri. Returned HTTP status code: $StatusCode"
              if ($StatusCode -eq 404) { $cts.Cancel() }
              throw [DownloadException]::new("Unable to download $Uri.", $StatusCode, $ErrMsg)
            }
            return $Response
          } catch [System.Net.Http.HttpRequestException] {
            $CurrentException = $_.Exception
            $ErrorMsg = "$($CurrentException.Message)`r`n"
            while ($CurrentException.InnerException) {
              $CurrentException = $CurrentException.InnerException
              $ErrorMsg += "$($CurrentException.Message)`r`n"
            }
            if ($ErrorMsg -match "SSL/TLS") { $ErrorMsg += "Ensure that TLS 1.2 or higher is enabled.`r`n" }
            throw [DownloadException]::new("Unable to download $Uri.", 0, $ErrorMsg)
          } finally {
            if ($null -ne $HttpClient) { $HttpClient.Dispose() }
          }
        }

        try {
          return [HttpUtils]::InvokeWithRetry($downloadScript, $cts.Token, 3, 1, $Ctx.DownloadTimeout)
        } finally {
          if ($null -ne $cts) { $cts.Dispose() }
        }
      }

      static [string] GetRemoteFileSize([string]$zipUri, [InstallContext]$Ctx) {
        try {
          $response = Invoke-WebRequest -UseBasicParsing -Uri $zipUri -Method Head
          $fileSize = $response.Headers["Content-Length"]
          if (![string]::IsNullOrEmpty($fileSize)) {
            [Logger]::Say("Remote file $zipUri size is $fileSize bytes.")
            return $fileSize
          }
        } catch {
          [Logger]::SayVerbose("Content-Length header was not extracted for $zipUri.")
        }
        return $null
      }

      static [void] ValidateRemoteLocalFileSizes([string]$LocalFileOutPath, [string]$SourceUri, [InstallContext]$Ctx) {
        try {
          $remoteFileSize = [HttpUtils]::GetRemoteFileSize($SourceUri, $Ctx)
          $fileSize = [long](Get-Item $LocalFileOutPath).Length
          [Logger]::Say("Downloaded file $SourceUri size is $fileSize bytes.")

          if (![string]::IsNullOrEmpty($remoteFileSize) -and $fileSize -gt 0) {
            if ($remoteFileSize -ne $fileSize) {
              [Logger]::Say("The remote and local file sizes are not equal. Remote file size is $remoteFileSize bytes and local size is $fileSize bytes. The local package may be corrupted.")
            } else {
              [Logger]::Say("The remote and local file sizes are equal.")
            }
          } else {
            [Logger]::Say("Either downloaded or local package size can not be measured. One of them may be corrupted.")
          }
        } catch {
          [Logger]::Say("Either downloaded or local package size can not be measured. One of them may be corrupted.")
        }
      }

      static [void] DownloadFile([string]$Source, [string]$OutPath, [InstallContext]$Ctx) {
        if ($Source -notlike "http*") {
          $absSource = [SystemUtils]::GetAbsolutePath($Source)
          [Logger]::Say("Copying file from $absSource to $OutPath")
          Copy-Item $absSource $OutPath
          return
        }

        $Stream = $null
        try {
          $Response = [HttpUtils]::GetHttpResponse($Source, $false, $false, $false, $Ctx)
          $Stream = $Response.Content.ReadAsStreamAsync().Result
          $File = [System.IO.File]::Create($OutPath)
          $Stream.CopyTo($File)
          $File.Close()
          [HttpUtils]::ValidateRemoteLocalFileSizes($OutPath, $Source, $Ctx)
        } finally {
          if ($null -ne $Stream) { $Stream.Dispose() }
        }
      }
    }

    class FileSystemUtils {
      static [string] GetUserSharePath() {
        $InstallRoot = $env:DOTNET_INSTALL_DIR
        if (!$InstallRoot) { $InstallRoot = "$env:LocalAppData\Microsoft\dotnet" }
        elseif ($InstallRoot -like "$env:ProgramFiles\dotnet\?*") {
          [Logger]::SayWarning("The install root specified by DOTNET_INSTALL_DIR points to a sub folder of $env:ProgramFiles\dotnet. It is better to keep aligned with .NET SDK installer.")
        }
        return $InstallRoot
      }

      static [bool] TestUserWriteAccess([string]$InstallDir) {
        try {
          $tempFileName = [guid]::NewGuid().ToString()
          $tempFilePath = Join-Path -Path $InstallDir -ChildPath $tempFileName
          New-Item -Path $tempFilePath -ItemType File -Force | Out-Null
          Remove-Item $tempFilePath -Force
          return $true
        } catch {
          return $false
        }
      }

      static [void] PrepareInstallDirectory([string]$InstallRoot) {
        $diskSpaceWarning = "Failed to check the disk space. Installation will continue, but it may fail if you do not have enough disk space."
        if ($(Get-Variable PSVersionTable).Value.PSVersion.Major -lt 7) {
          [Logger]::SayVerbose($diskSpaceWarning)
          return
        }

        New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
        $installDrive = $((Get-Item $InstallRoot -Force).PSDrive.Name)
        $diskInfo = $null
        try { $diskInfo = Get-PSDrive -Name $installDrive } catch { [Logger]::SayWarning($diskSpaceWarning) }

        if (($null -ne $diskInfo) -and ($diskInfo.Free / 1MB -le 100)) {
          throw [DotnetInstallException]::new("There is not enough disk space on drive ${installDrive}:")
        }
      }

      static [bool] IsDotnetPackageInstalled([string]$InstallRoot, [string]$RelativePath, [string]$SpecificVersion) {
        $DotnetPackagePath = Join-Path -Path (Join-Path -Path $InstallRoot -ChildPath $RelativePath) -ChildPath $SpecificVersion
        [Logger]::SayVerbose("Is-Dotnet-Package-Installed: DotnetPackagePath=$DotnetPackagePath")
        return (Test-Path $DotnetPackagePath -PathType Container)
      }

      static [string] GetPathPrefixWithVersion([string]$Path) {
        $match = [regex]::Match($Path, "/\d+\.\d+[^/]+/")
        if ($match.Success) { return $Path.Substring(0, $match.Index + $match.Length) }
        return $null
      }

      static [string[]] GetDirectoriesToUnpack([object]$Zip, [string]$OutPath) {
        $ret = @()
        foreach ($entry in $Zip.Entries) {
          $dir = [FileSystemUtils]::GetPathPrefixWithVersion($entry.FullName)
          if ($null -ne $dir) {
            $path = [SystemUtils]::GetAbsolutePath((Join-Path -Path $OutPath -ChildPath $dir))
            if (-not (Test-Path $path -PathType Container)) { $ret += $dir }
          }
        }
        $ret = $ret | Sort-Object | Get-Unique
        [Logger]::SayVerbose("Directories to unpack: $(($ret | ForEach-Object { "$_" }) -join ';')")
        return $ret
      }

      static [void] ExtractDotnetPackage([string]$ZipPath, [string]$OutPath, [bool]$OverrideNonVersionedFiles) {
        [SystemUtils]::LoadAssembly("System.IO.Compression.FileSystem")
        $Zip = $null
        try {
          $Zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
          $DirectoriesToUnpack = [FileSystemUtils]::GetDirectoriesToUnpack($Zip, $OutPath)

          foreach ($entry in $Zip.Entries) {
            $PathWithVersion = [FileSystemUtils]::GetPathPrefixWithVersion($entry.FullName)
            if (($null -eq $PathWithVersion) -or ($DirectoriesToUnpack -contains $PathWithVersion)) {
              $DestinationPath = [SystemUtils]::GetAbsolutePath((Join-Path -Path $OutPath -ChildPath $entry.FullName))
              $DestinationDir = Split-Path -Parent $DestinationPath
              $OverrideFiles = $OverrideNonVersionedFiles -or (-not (Test-Path $DestinationPath))
              if ((-not $DestinationPath.EndsWith("\")) -and $OverrideFiles) {
                New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $DestinationPath, $OverrideNonVersionedFiles)
              }
            }
          }
        } catch {
          throw [DotnetInstallException]::new("Failed to extract package.", $_.Exception)
        } finally {
          if ($null -ne $Zip) { $Zip.Dispose() }
        }
      }

      static [void] SafeRemoveFile([string]$Path) {
        try {
          if (Test-Path $Path) {
            Remove-Item $Path -Force
            [Logger]::SayVerbose("The temporary file `"$Path`" was removed.")
          }
        } catch {
          [Logger]::SayWarning("Failed to remove the temporary file: `"$Path`", remove it manually.")
        }
      }
    }

    class VersionResolver {
      static [string] ParseJsonFile([string]$JSonFile) {
        if (-not (Test-Path $JSonFile)) { throw [DotnetInstallException]::new("Unable to find '$JSonFile'") }
        try {
          $JSonContent = Get-Content($JSonFile) -Raw | ConvertFrom-Json | Select-Object -expand "sdk" -ErrorAction SilentlyContinue
        } catch {
          [Logger]::SayError("Json file unreadable: '$JSonFile'")
          throw
        }

        $Version = $null
        if ($JSonContent) {
          try {
            foreach ($prop in $JSonContent.PSObject.Properties) {
              if ($prop.Name -eq "version") {
                $Version = $prop.Value
                [Logger]::SayVerbose("Version = $Version")
              }
            }
          } catch {
            throw [DotnetInstallException]::new("Unable to parse the SDK node in '$JSonFile'")
          }
        } else {
          throw [DotnetInstallException]::new("Unable to find the SDK node in '$JSonFile'")
        }

        if ($null -eq $Version) { throw [DotnetInstallException]::new("Unable to find the SDK:version node in '$JSonFile'") }
        return $Version
      }

      static [hashtable] GetFromLatestVersionFile([string]$AzureFeed, [string]$Channel, [string]$Runtime, [InstallContext]$Ctx) {
        $VersionFileUrl = $null
        if ($Runtime -eq "dotnet") { $VersionFileUrl = "$AzureFeed/Runtime/$Channel/latest.version" }
        elseif ($Runtime -eq "aspnetcore") { $VersionFileUrl = "$AzureFeed/aspnetcore/Runtime/$Channel/latest.version" }
        elseif ($Runtime -eq "windowsdesktop") { $VersionFileUrl = "$AzureFeed/WindowsDesktop/$Channel/latest.version" }
        elseif (-not $Runtime) { $VersionFileUrl = "$AzureFeed/Sdk/$Channel/latest.version" }

        [Logger]::SayVerbose("Constructed latest.version URL: $VersionFileUrl")
        $Response = [HttpUtils]::GetHttpResponse($VersionFileUrl, $false, $false, $false, $Ctx)
        $VersionText = $Response.Content.ReadAsStringAsync().Result
        $Data = -split $VersionText

        return @{
          CommitHash = $(if ($Data.Count -gt 1) { $Data[0] })
          Version    = $Data[-1]
        }
      }

      static [string] GetProductVersion([string]$AzureFeed, [string]$SpecificVersion, [string]$DownloadLink, [string]$Runtime, [InstallContext]$Ctx) {
        $urls = @(
          [VersionResolver]::GetProductVersionUrl($AzureFeed, $SpecificVersion, $DownloadLink, $true, $Runtime),
          [VersionResolver]::GetProductVersionUrl($AzureFeed, $SpecificVersion, $DownloadLink, $false, $Runtime)
        )

        foreach ($url in $urls) {
          [Logger]::SayVerbose("Checking for the existence of $url")
          try {
            $response = [HttpUtils]::GetHttpResponse($url, $false, $false, $false, $Ctx)
            if ($response.StatusCode -eq 200) {
              $pv = $response.Content.ReadAsStringAsync().Result.Trim()
              if ($pv -ne $SpecificVersion) { [Logger]::Say("Using alternate version $pv found in $url") }
              return $pv
            }
          } catch { [Logger]::SayVerbose("Could not read productVersion.txt at $url") }
        }

        if ([string]::IsNullOrEmpty($DownloadLink)) { return $SpecificVersion }

        $filename = $DownloadLink.Substring($DownloadLink.LastIndexOf("/") + 1)
        $filenameParts = $filename.Split('-')
        if ($filenameParts.Length -gt 2) {
          $pv = $filenameParts[2]
          [Logger]::SayVerbose("Extracted product version '$pv' from download link '$DownloadLink'.")
          return $pv
        }
        return $SpecificVersion
      }

      static [string] GetProductVersionUrl([string]$AzureFeed, [string]$SpecificVersion, [string]$DownloadLink, [bool]$Flattened, [string]$Runtime) {
        $majorVersion = $null
        if ($SpecificVersion -match '^(\d+)\.(.*)') { $majorVersion = $Matches[1] -as [int] }

        $pvFileName = 'productVersion.txt'
        if ($Flattened) {
          if (-not $Runtime) { $pvFileName = 'sdk-productVersion.txt' }
          elseif ($Runtime -eq "dotnet") { $pvFileName = 'runtime-productVersion.txt' }
          else { $pvFileName = "$Runtime-productVersion.txt" }
        }

        if ([string]::IsNullOrEmpty($DownloadLink)) {
          if ($Runtime -eq "dotnet") { return "$AzureFeed/Runtime/$SpecificVersion/$pvFileName" }
          elseif ($Runtime -eq "aspnetcore") { return "$AzureFeed/aspnetcore/Runtime/$SpecificVersion/$pvFileName" }
          elseif ($Runtime -eq "windowsdesktop") {
            if ($null -ne $majorVersion -and $majorVersion -ge 5) { return "$AzureFeed/WindowsDesktop/$SpecificVersion/$pvFileName" }
            return "$AzureFeed/Runtime/$SpecificVersion/$pvFileName"
          } elseif (-not $Runtime) { return "$AzureFeed/Sdk/$SpecificVersion/$pvFileName" }
        }
        return $DownloadLink.Substring(0, $DownloadLink.LastIndexOf("/")) + "/$pvFileName"
      }
    }

    class UrlResolver {
      static [string] GetAkaMSDownloadLink([string]$Channel, [string]$Quality, [bool]$Internal, [string]$Product, [string]$Architecture, [InstallContext]$Ctx) {
        if (![string]::IsNullOrEmpty($Quality) -and ($Channel -in "LTS", "STS")) {
          $Quality = ""
          [Logger]::SayWarning("Specifying quality for STS or LTS channel is not supported, the quality will be ignored.")
        }

        $akaMsLink = "https://aka.ms/dotnet"
        if ($Internal) { $akaMsLink += "/internal" }
        $akaMsLink += "/$Channel"
        if (-not [string]::IsNullOrEmpty($Quality)) { $akaMsLink += "/$Quality" }
        $akaMsLink += "/$Product-win-$Architecture.zip"

        [Logger]::SayVerbose("Constructed aka.ms link: '$akaMsLink'.")
        $downloadLink = $null

        for ($maxRedirections = 9; $maxRedirections -ge 0; $maxRedirections--) {
          $Response = [HttpUtils]::GetHttpResponse($akaMsLink, $true, $true, $true, $Ctx)
          if ([string]::IsNullOrEmpty($Response)) { return $null }

          if ($Response.StatusCode -eq 301) {
            try {
              $downloadLink = $Response.Headers.GetValues("Location")[0]
              if ([string]::IsNullOrEmpty($downloadLink)) { return $null }
              $akaMsLink = $downloadLink
              continue
            } catch { return $null }
          } elseif ((($Response.StatusCode -lt 300) -or ($Response.StatusCode -ge 400)) -and (-not [string]::IsNullOrEmpty($downloadLink))) {
            return $downloadLink
          }
          return $null
        }
        return $null
      }

      static [DownloadLinkInfo] GetAkaMsLinkAndVersion([InstallContext]$Ctx) {
        $link = [UrlResolver]::GetAkaMSDownloadLink($Ctx.NormalizedChannel, $Ctx.NormalizedQuality, $Ctx.Internal, $Ctx.NormalizedProduct, $Ctx.CLIArchitecture, $Ctx)
        if ([string]::IsNullOrEmpty($link)) {
          if (-not [string]::IsNullOrEmpty($Ctx.NormalizedQuality)) {
            [Logger]::SayError("Failed to locate the latest version in channel '$($Ctx.NormalizedChannel)' with '$($Ctx.NormalizedQuality)' quality.")
            throw [DotnetInstallException]::new("aka.ms link resolution failure")
          }
          return $null
        }

        $pathParts = $link.Split('/')
        if ($pathParts.Length -ge 2) {
          $SpecificVersion = $pathParts[$pathParts.Length - 2]
        } else {
          [Logger]::SayError("Failed to extract the version from download link '$link'.")
          return $null
        }

        $EffectiveVersion = [VersionResolver]::GetProductVersion($null, $SpecificVersion, $link, $Ctx.Runtime, $Ctx)
        $info = [DownloadLinkInfo]::new()
        $info.DownloadLink = $link
        $info.SpecificVersion = $SpecificVersion
        $info.EffectiveVersion = $EffectiveVersion
        $info.Type = "aka.ms"
        return $info
      }

      static [string[]] GetFeedsToUse([InstallContext]$Ctx) {
        $feeds = @("https://builds.dotnet.microsoft.com/dotnet", "https://ci.dot.net/public")
        if (-not [string]::IsNullOrEmpty($Ctx.AzureFeed)) { $feeds = @($Ctx.AzureFeed) }
        if (-not [string]::IsNullOrEmpty($Ctx.UncachedFeed)) { $feeds = @($Ctx.UncachedFeed) }
        return $feeds
      }
    }

    class DotnetInstall {
      static [void] ValidateFeedCredential([InstallContext]$Ctx) {
        if ($Ctx.Internal -and [string]::IsNullOrWhitespace($Ctx.FeedCredential)) {
          $msg = "Provide credentials via -FeedCredential parameter."
          if ($Ctx.DryRun) { [Logger]::SayWarning($msg) } else { throw [DotnetInstallException]::new($msg) }
        }
        if (-not [string]::IsNullOrWhitespace($Ctx.FeedCredential) -and $Ctx.FeedCredential[0] -ne '?') {
          $Ctx.FeedCredential = "?" + $Ctx.FeedCredential
        }
      }

      static [void] NormalizeParameters([InstallContext]$Ctx) {
        $Ctx.CLIArchitecture = [SystemUtils]::GetCLIArchitecture($Ctx.Architecture)

        # Quality
        if ([string]::IsNullOrEmpty($Ctx.Quality)) { $Ctx.NormalizedQuality = "" }
        else {
          switch ($Ctx.Quality.ToLowerInvariant()) {
            { $_ -in "daily", "preview" } { $Ctx.NormalizedQuality = $_ }
            { $_ -eq "ga" } { $Ctx.NormalizedQuality = "" }
            default { throw [DotnetInstallException]::new("'$($Ctx.Quality)' is not a supported value for -Quality option.") }
          }
        }

        # Channel
        if ([string]::IsNullOrEmpty($Ctx.Channel)) { $Ctx.NormalizedChannel = "" }
        else {
          if ($Ctx.Channel.Contains("Current")) { [Logger]::SayWarning('Value "Current" is deprecated. Use "STS" instead.') }
          switch ($Ctx.Channel.ToLowerInvariant()) {
            { $_ -eq "lts" } { $Ctx.NormalizedChannel = "LTS" }
            { $_ -in "sts", "current" } { $Ctx.NormalizedChannel = "STS" }
            default { $Ctx.NormalizedChannel = $Ctx.Channel.ToLowerInvariant() }
          }
        }

        # Product & Runtime
        switch ($Ctx.Runtime) {
          { $_ -eq "dotnet" } {
            $Ctx.NormalizedProduct = "dotnet-runtime"
            $Ctx.AssetName = ".NET Core Runtime"
            $Ctx.DotnetPackageRelativePath = "shared\Microsoft.NETCore.App"
          }
          { $_ -eq "aspnetcore" } {
            $Ctx.NormalizedProduct = "aspnetcore-runtime"
            $Ctx.AssetName = "ASP.NET Core Runtime"
            $Ctx.DotnetPackageRelativePath = "shared\Microsoft.AspNetCore.App"
          }
          { $_ -eq "windowsdesktop" } {
            $Ctx.NormalizedProduct = "windowsdesktop-runtime"
            $Ctx.AssetName = ".NET Core Windows Desktop Runtime"
            $Ctx.DotnetPackageRelativePath = "shared\Microsoft.WindowsDesktop.App"
          }
          { [string]::IsNullOrEmpty($_) } {
            $Ctx.NormalizedProduct = "dotnet-sdk"
            $Ctx.AssetName = ".NET Core SDK"
            $Ctx.DotnetPackageRelativePath = "sdk"
          }
          default { throw [DotnetInstallException]::new("'$($Ctx.Runtime)' is not a supported value for -Runtime option.") }
        }

        [DotnetInstall]::ValidateFeedCredential($Ctx)
      }

      static [void] PrintDryRunOutput([InstallContext]$Ctx, [DownloadLinkInfo[]]$Links) {
        [Logger]::Say("Payload URLs:")
        for ($i = 0; $i -lt $Links.Count; $i++) {
          [Logger]::Say("URL #$i - $($Links[$i].Type): $($Links[$i].DownloadLink)")
        }

        $SpecificVersion = $Links[0].SpecificVersion
        $EffectiveVersion = $Links[0].EffectiveVersion

        $cmd = ".\$($Ctx.ScriptName) -Version `"$SpecificVersion`" -InstallDir `"$($Ctx.InstallRoot)`" -Architecture `"$($Ctx.CLIArchitecture)`""
        if ($Ctx.Runtime -in "dotnet", "aspnetcore") { $cmd += " -Runtime `"$($Ctx.Runtime)`"" }

        foreach ($key in $Ctx.Invocation.BoundParameters.Keys) {
          if ($key -notin @("Architecture", "Channel", "DryRun", "InstallDir", "Runtime", "SharedRuntime", "Version", "Quality", "FeedCredential")) {
            $cmd += " -$key `"$($Ctx.Invocation.BoundParameters[$key])`""
          }
        }
        if ($Ctx.Invocation.BoundParameters.ContainsKey("FeedCredential")) { $cmd += " -FeedCredential `"<feedCredential>`"" }

        [Logger]::Say("Repeatable invocation: $cmd")
        if ($SpecificVersion -ne $EffectiveVersion) {
          [Logger]::Say("NOTE: Due to finding a version manifest with this runtime, it would actually install with version '$EffectiveVersion'")
        }
      }

      static [void] Run([InstallContext]$Ctx) {
        [Logger]::SayVerbose("Note that the intended use of this script is for Continuous Integration (CI) scenarios...")
        if ($Ctx.SharedRuntime -and (-not $Ctx.Runtime)) { $Ctx.Runtime = "dotnet" }
        $OverrideNonVersionedFiles = !$Ctx.SkipNonVersionedFiles

        [Logger]::MeasureAction("Product discovery", { [DotnetInstall]::NormalizeParameters($Ctx) })

        $Ctx.InstallRoot = if ($Ctx.InstallDir -eq "<auto>") { [FileSystemUtils]::GetUserSharePath() } else { $Ctx.InstallDir }
        if (-not [FileSystemUtils]::TestUserWriteAccess($Ctx.InstallRoot)) {
          [Logger]::SayError("The current user doesn't have write access to the installation root '$($Ctx.InstallRoot)'")
          throw [DotnetInstallException]::new("Access Denied")
        }
        [Logger]::SayVerbose("InstallRoot: $($Ctx.InstallRoot)")

        if ($Ctx.Version.ToLowerInvariant() -ne "latest" -and -not [string]::IsNullOrEmpty($Ctx.Quality)) {
          throw [DotnetInstallException]::new("Quality and Version options are not allowed to be specified simultaneously.")
        }

        $DownloadLinks = @()

        # aka.ms strategy
        if ([string]::IsNullOrEmpty($Ctx.JSonFile) -and ($Ctx.Version -eq "latest")) {
          $akaLinkInfo = [UrlResolver]::GetAkaMsLinkAndVersion($Ctx)
          if ($null -ne $akaLinkInfo) {
            $DownloadLinks += $akaLinkInfo
            if (-not $Ctx.DryRun -and [FileSystemUtils]::IsDotnetPackageInstalled($Ctx.InstallRoot, $Ctx.DotnetPackageRelativePath, $akaLinkInfo.EffectiveVersion)) {
              [Logger]::Say("$($Ctx.AssetName) with version '$($akaLinkInfo.EffectiveVersion)' is already installed.")
              [SystemUtils]::PrependToPath($Ctx.InstallRoot, $Ctx.NoPath)
              return
            }
          }
        }

        # feed strategy
        if ([string]::IsNullOrEmpty($Ctx.NormalizedQuality) -and $DownloadLinks.Count -eq 0) {
          $feeds = [UrlResolver]::GetFeedsToUse($Ctx)
          foreach ($feed in $feeds) {
            try {
              $SpecificVersion = if (-not $Ctx.JSonFile) {
                if ($Ctx.Version.ToLowerInvariant() -eq "latest") {
                  ([VersionResolver]::GetFromLatestVersionFile($feed, $Ctx.Channel, $Ctx.Runtime, $Ctx)).Version
                } else { $Ctx.Version }
              } else { [VersionResolver]::ParseJsonFile($Ctx.JSonFile) }

              # Build primary download link
              $ProductVersion = [VersionResolver]::GetProductVersion($feed, $SpecificVersion, $null, $Ctx.Runtime, $Ctx)
              $Link = if ($Ctx.Runtime -eq "dotnet") { "$feed/Runtime/$SpecificVersion/dotnet-runtime-$ProductVersion-win-$($Ctx.CLIArchitecture).zip" }
              elseif ($Ctx.Runtime -eq "aspnetcore") { "$feed/aspnetcore/Runtime/$SpecificVersion/aspnetcore-runtime-$ProductVersion-win-$($Ctx.CLIArchitecture).zip" }
              elseif ($Ctx.Runtime -eq "windowsdesktop") {
                if ($SpecificVersion -match '^(\d+)\.(.*)$' -and [int]$Matches[1] -ge 5) { "$feed/WindowsDesktop/$SpecificVersion/windowsdesktop-runtime-$ProductVersion-win-$($Ctx.CLIArchitecture).zip" }
                else { "$feed/Runtime/$SpecificVersion/windowsdesktop-runtime-$ProductVersion-win-$($Ctx.CLIArchitecture).zip" }
              } else { "$feed/Sdk/$SpecificVersion/dotnet-sdk-$ProductVersion-win-$($Ctx.CLIArchitecture).zip" }

              $infoPrimary = [DownloadLinkInfo]::new()
              $infoPrimary.DownloadLink = $Link
              $infoPrimary.SpecificVersion = $SpecificVersion
              $infoPrimary.EffectiveVersion = $ProductVersion
              $infoPrimary.Type = "primary"
              $DownloadLinks += $infoPrimary

              # Build legacy download link
              $LegacyLink = if (-not $Ctx.Runtime) { "$feed/Sdk/$SpecificVersion/dotnet-dev-win-$($Ctx.CLIArchitecture).$SpecificVersion.zip" }
              elseif ($Ctx.Runtime -eq "dotnet") { "$feed/Runtime/$SpecificVersion/dotnet-win-$($Ctx.CLIArchitecture).$SpecificVersion.zip" }
              else { $null }

              if (-not [string]::IsNullOrEmpty($LegacyLink)) {
                $infoLegacy = [DownloadLinkInfo]::new()
                $infoLegacy.DownloadLink = $LegacyLink
                $infoLegacy.SpecificVersion = $SpecificVersion
                $infoLegacy.EffectiveVersion = $ProductVersion
                $infoLegacy.Type = "legacy"
                $DownloadLinks += $infoLegacy
              }

              if (-not $Ctx.DryRun -and [FileSystemUtils]::IsDotnetPackageInstalled($Ctx.InstallRoot, $Ctx.DotnetPackageRelativePath, $ProductVersion)) {
                [Logger]::Say("$($Ctx.AssetName) with version '$ProductVersion' is already installed.")
                [SystemUtils]::PrependToPath($Ctx.InstallRoot, $Ctx.NoPath)
                return
              }
            } catch { [Logger]::SayVerbose("Failed to acquire download links from feed $feed.") }
          }
        }

        if ($DownloadLinks.Count -eq 0) { throw [DotnetInstallException]::new("Failed to resolve the exact version number.") }

        if ($Ctx.DryRun) {
          [DotnetInstall]::PrintDryRunOutput($Ctx, $DownloadLinks)
          return
        }

        [Logger]::MeasureAction("Installation directory preparation", { [FileSystemUtils]::PrepareInstallDirectory($Ctx.InstallRoot) })

        $DownloadSucceeded = $false
        $DownloadedLink = $null
        $ErrorMessages = @()

        foreach ($linkInfo in $DownloadLinks) {
          [Logger]::SayVerbose("Downloading `"$($linkInfo.Type)`" link $($linkInfo.DownloadLink)")
          try {
            [Logger]::MeasureAction("Package download", { [HttpUtils]::DownloadFile($linkInfo.DownloadLink, $Ctx.ZipPath, $Ctx) })
            $DownloadSucceeded = $true
            $DownloadedLink = $linkInfo
            break
          } catch {
            $StatusCode = if ($_.Exception -is [DownloadException]) { $_.Exception.StatusCode } else { 0 }
            $ErrMsg = if ($_.Exception -is [DownloadException]) { $_.Exception.ErrorMessage } else { $_.Exception.Message }
            [Logger]::SayVerbose("Download failed. Status: $StatusCode. Msg: $ErrMsg")
            $ErrorMessages += "Downloading from `"$($linkInfo.Type)`" link failed:`nUri: $($linkInfo.DownloadLink)`nStatusCode: $StatusCode`nError: $ErrMsg"
            [FileSystemUtils]::SafeRemoveFile($Ctx.ZipPath)
          }
        }

        if (-not $DownloadSucceeded) {
          foreach ($err in $ErrorMessages) { [Logger]::SayError($err) }
          throw [DotnetInstallException]::new("Could not find `"$($Ctx.AssetName)`" with version = $($DownloadLinks[0].EffectiveVersion)")
        }

        [Logger]::Say("Extracting the archive.")
        [Logger]::MeasureAction("Package extraction", { [FileSystemUtils]::ExtractDotnetPackage($Ctx.ZipPath, $Ctx.InstallRoot, $OverrideNonVersionedFiles) })

        $isAssetInstalled = $false
        if ($DownloadedLink.EffectiveVersion -match "rtm" -or $DownloadedLink.EffectiveVersion -match "servicing") {
          $ReleaseVersion = $DownloadedLink.EffectiveVersion.Split("-")[0]
          $isAssetInstalled = [FileSystemUtils]::IsDotnetPackageInstalled($Ctx.InstallRoot, $Ctx.DotnetPackageRelativePath, $ReleaseVersion)
        }
        if (-not $isAssetInstalled) {
          $isAssetInstalled = [FileSystemUtils]::IsDotnetPackageInstalled($Ctx.InstallRoot, $Ctx.DotnetPackageRelativePath, $DownloadedLink.EffectiveVersion)
        }

        if (-not $isAssetInstalled) {
          throw [DotnetInstallException]::new("`"$($Ctx.AssetName)`" with version = $($DownloadedLink.EffectiveVersion) failed to install with an unknown error.")
        }

        if (-not $Ctx.KeepZip) { [FileSystemUtils]::SafeRemoveFile($Ctx.ZipPath) }
        [Logger]::MeasureAction("Setting up shell environment", { [SystemUtils]::PrependToPath($Ctx.InstallRoot, $Ctx.NoPath) })

        [Logger]::Say("Note that the script does not ensure your Windows version is supported during the installation.")
        [Logger]::Say("Installed version is $($DownloadedLink.EffectiveVersion)")
        [Logger]::Say("Installation finished")
      }
    }
  }

  process {
    $context = [InstallContext]::new()
    $context.Channel = $Channel
    $context.Quality = $Quality
    $context.Version = $Version
    $context.Internal = $Internal.IsPresent
    $context.JSonFile = $JSonFile
    $context.InstallDir = $InstallDir
    $context.Architecture = $Architecture
    $context.Runtime = $Runtime
    $context.SharedRuntime = $SharedRuntime.IsPresent
    $context.DryRun = $DryRun.IsPresent
    $context.NoPath = $NoPath.IsPresent
    $context.AzureFeed = $AzureFeed
    $context.UncachedFeed = $UncachedFeed
    $context.FeedCredential = $FeedCredential
    $context.ProxyAddress = $ProxyAddress
    $context.ProxyUseDefaultCredentials = $ProxyUseDefaultCredentials.IsPresent
    $context.ProxyBypassList = $ProxyBypassList
    $context.SkipNonVersionedFiles = $SkipNonVersionedFiles.IsPresent
    $context.DownloadTimeout = $DownloadTimeout
    $context.KeepZip = $KeepZip.IsPresent
    $context.ZipPath = $ZipPath
    $context.Invocation = $MyInvocation

    [DotnetInstall]::Run($context)
  }

  end {
    $ErrorActionPreference = $ogeap
    $ProgressPreference = $ogpap
  }
}