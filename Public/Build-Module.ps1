function Build-Module {
  # .SYNOPSIS
  #    Module buildScript
  # .DESCRIPTION
  #    A custom Psake buildScript for any module that was created by PsCraft.
  # .EXAMPLE
  #    Running Build-Module will only "Compile & Import" the module; That's it, no tests.
  #    To run tests Use:
  #    Build-Module Test
  #    This Will build the module, Import it and run tests using the ./Test-Module.ps1 script.
  # .EXAMPLE
  #    Build-Module deploy
  #    Will build the module, test it and deploy it to PsGallery
  # .LINK
  #    https://github.com/chadnpc/PsCraft/blob/main/public/Build-Module.ps1
  [cmdletbinding(DefaultParameterSetName = 'task')]
  param(
    [parameter(Mandatory = $false, Position = 0, ParameterSetName = 'task')]
    [ValidateScript({
        $task_seq = [string[]]$_; $IsValid = $true
        $Tasks = @('Clean', 'Compile', 'Test', 'Deploy')
        foreach ($name in $task_seq) {
          $IsValid = $IsValid -and ($name -in $Tasks)
        }
        if ($IsValid) {
          return $true
        } else {
          throw [System.ArgumentException]::new('Task', "ValidSet: $($Tasks -join ', ').")
        }
      }
    )][ValidateNotNullOrEmpty()][Alias('t')]
    [string[]]$Task = 'Test',

    # Module buildRoot
    [Parameter(Mandatory = $false, Position = 1, ParameterSetName = 'task')]
    [ValidateScript({
        if (Test-Path -Path $_ -PathType Container -ea Ignore) {
          return $true
        } else {
          throw [System.ArgumentException]::new('Path', "Path: $_ is not a valid directory.")
        }
      })][Alias('p')]
    [string]$Path = (Resolve-Path .).Path,

    [Parameter(Mandatory = $false, ParameterSetName = 'task')]
    [string[]]$RequiredModules = @(),

    [Parameter(Mandatory = $false, ParameterSetName = 'task')]
    [Alias('u')][ValidateNotNullOrWhiteSpace()]
    [string]$gitUser,

    [parameter(ParameterSetName = 'task')]
    [Alias('i')]
    [switch]$Import,

    [parameter(ParameterSetName = 'help')]
    [Alias('h', '-help')]
    [switch]$Help
  )

  Begin {
    #Requires -RunAsAdministrator
    #Requires -Psedition Core
    #Requires -Modules cliHelper.core
    $script:build_requirements = $($RequiredModules + @(
        "PackageManagement", "PSScriptAnalyzer",
        "cliHelper.env", "cliHelper.core",
        "PsCraft", "Pester", "psake")
    ) | Select-Object -Unique # ie: defaults /really essential.
    $script:PSake_ScriptBlock = [scriptblock]::Create({
        Properties {
          # variables that will be available to all tasks in the build script
          $taskList = $Task
          $Cmdlet = $PSCmdlet
          $ProjectName = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
          $BuildNumber = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildNumber')
          $ProjectRoot = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectPath')
          $outputDir = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput')
          $PSVersion = $PSVersionTable.PSVersion.ToString()
          $outputModDir = [IO.path]::Combine([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput'), $ProjectName)
          $tests = [IO.Path]::Combine($projectRoot, "Tests")
          $lines = ('-' * 70);
          $TestFile = "TestResults_PS${PSVersion}_$(Get-Date -UFormat %Y%m%d-%H%M%S).xml"
          $outputModVerDir = [IO.path]::Combine([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput'), $ProjectName, $BuildNumber)
          $PathSeperator = [IO.Path]::PathSeparator
          $DirSeperator = [IO.Path]::DirectorySeparatorChar
          $buildrequirements = <build_requirements>
          # To prevent "variable not used" warnings:
          $null = @($taskList, $Cmdlet, $tests, $getelapsed, $TestFile, $ProjectRoot, $outputDir, $outputModDir, $outputModVerDir, $lines, $DirSeperator, $PathSeperator, $buildrequirements)
        }

        Task default -Depends Test

        Task Compile -Depends Clean {
          $security_protocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::SystemDefault
          if ([Net.SecurityProtocolType].GetMember("Tls12").Count -gt 0) { $security_protocol = $security_protocol -bor [Net.SecurityProtocolType]::Tls12 }
          [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]$security_protocol
          $buildrequirements.ForEach({ Import-Module $_ -Verbose:$false -ea Stop }); $Host.ui.WriteLine();
          #Make sure everything is updated to the latest version:
          $target = "https://www.powershellgallery.com"; $Isconnected = $(try { [System.Net.NetworkInformation.PingReply]$PingReply = [System.Net.NetworkInformation.Ping]::new().Send($target); $PingReply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success } catch [System.Net.Sockets.SocketException], [System.Net.NetworkInformation.PingException] { Write-Verbose "Ping $target : $($_.Exception.InnerException.Message)"; $false });
          if ($Isconnected) { $buildrequirements | PsCraft\Resolve-Module -Update -Verbose:$false }
          Write-EnvironmentSummary "Initialize [$ProjectName] build environment"
          Set-Location $ProjectRoot; Write-Verbose "Module Build version: $BuildNumber"
          $Host.ui.WriteLine()
          Invoke-CommandWithLog { $script:DefaultParameterValues = @{
              '*-Module:Verbose'           = $false
              'Import-Module:ErrorAction'  = 'Stop'
              'Import-Module:Force'        = $true
              'Import-Module:Verbose'      = $false
              'Install-Module:ErrorAction' = 'Stop'
              'Install-Module:Scope'       = 'CurrentUser'
              'Install-Module:Verbose'     = $false
            }
          }
          Write-Heading "Prepare package feeds"
          $Host.ui.WriteLine()
          if ($null -eq (Get-PSRepository -Name PSGallery -ea Ignore)) {
            Unregister-PSRepository -Name PSGallery -Verbose:$false -ea Ignore
            Register-PSRepository -Default -InstallationPolicy Trusted
          }
          if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
            Invoke-CommandWithLog { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -Verbose:$false }
          }
          # if ((Get-Command dotnet -ea Ignore) -and ([bool](Get-Variable -Name IsWindows -ea Ignore) -and !$(Get-Variable IsWindows -ValueOnly))) {
          #     dotnet dev-certs https --trust
          # }
          Invoke-CommandWithLog { Get-PackageProvider -Name Nuget -ForceBootstrap -Verbose:$false }
          if (!(Get-PackageProvider -Name Nuget)) {
            Invoke-CommandWithLog { Install-PackageProvider -Name NuGet -Force | Out-Null }
          }
          $build_sys = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildSystem');
          $lastCommit = $(try { git log -1 --pretty=%B } catch { Write-Warning $_; [string]::Empty })
          Write-BuildLog "Current build system is $build_sys"
          Write-Heading "Finalizing build Prerequisites and Resolving dependencies ..."

          if ($build_sys -eq 'VSTS' -or ($env:CI -eq "true" -and $env:GITHUB_RUN_ID)) {
            if ($Task -contains 'Deploy') {
              $MSG = "Task is 'Deploy' and conditions for deployment are:`n" +
              "    + GitHub API key is not null       : $(![string]::IsNullOrWhiteSpace($env:GitHubPAT))`n" +
              "    + Current branch is main           : $(($env:GITHUB_REF -replace "refs/heads/") -eq 'main')`n" +
              "    + Source is not a pull request     : $($env:GITHUB_EVENT_NAME -ne "pull_request") [$env:GITHUB_EVENT_NAME]`n" +
              "    + Commit message matches '!deploy' : $($lastCommit -match "!deploy") [$lastCommit]`n" +
              "    + Is Current PS version < 5 ?      : $($PSVersionTable.PSVersion.Major -lt 5) [$($PSVersionTable.PSVersion.ToString())]`n" +
              "    + NuGet API key is not null        : $(![string]::IsNullOrWhiteSpace($env:NUGETAPIKEY))`n"
              if ($PSVersionTable.PSVersion.Major -lt 5 -or [string]::IsNullOrWhiteSpace($env:NUGETAPIKEY) -or [string]::IsNullOrWhiteSpace($env:GitHubPAT) ) {
                $MSG = $MSG.Replace('and conditions for deployment are:', 'but conditions are not correct for deployment.')
                $MSG | Write-Host -f Yellow
                if (($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')) -match '!deploy' -and $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BranchName')) -eq "main") -or $script:ForceDeploy -eq $true) {
                  Write-Warning "Force Deploying detected"
                } else {
                  "Skipping Psake for this job!" | Write-Host -f Yellow
                  return
                }
              } else {
                $MSG | Write-Host -f Green
              }
            }
          }

          Write-Verbose "Create module Output directory"
          New-Item -Path $outputModVerDir -ItemType Directory -Force -ea SilentlyContinue | Out-Null
          $ModuleManifest = [IO.FileInfo]::New([Environment]::GetEnvironmentVariable($env:RUN_ID + 'PSModuleManifest'))
          Write-BuildLog "Add Module files ...`nRef: https://aka.ms/nuget/authoring-best-practices"
          try {
            $d = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'PSModulePath')
            @(
              "en-US"
              "Private"
              "Public"
              "LICENSE"
              "README.md"
              "$($ModuleManifest.Name)"
              "$ProjectName.psm1"
            ).ForEach({
                $p = [IO.Path]::Combine($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildScriptPath')), $_)
                if (Test-Path -Path $p -ea Ignore) {
                  Copy-Item -Recurse -Path $p -Destination $d
                }
              }
            )
          } catch {
            $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new($_.Exception, $_.FullyQualifiedErrorId, $_.CategoryInfo, $_.TargetObject))
          }
          if (!$ModuleManifest.Exists) {
            $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new([IO.FileNotFoundException]::New('Could Not Create Module Manifest!'), 'CouldNotCreateModuleManifest', 'ObjectNotFound', $ModuleManifest))
          }
          $functionsToExport = @(); $publicFunctionsPath = [IO.Path]::Combine([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectPath'), "Public")
          if (Test-Path $publicFunctionsPath -PathType Container -ea SilentlyContinue) {
            Get-ChildItem -Path $publicFunctionsPath -Filter "*.ps1" -Recurse -File | ForEach-Object {
              $functionsToExport += $_.BaseName
            }
          }
          $manifestContent = Get-Content -Path $ModuleManifest -Raw
          $publicFunctionNames = Get-ChildItem -Path $publicFunctionsPath -Filter "*.ps1" | Select-Object -ExpandProperty BaseName

          Write-Verbose -Message "Editing $($ModuleManifest.Name) ..."
          # Using .Replace() is Better than Update-ModuleManifest as this does not destroy the Indentation in the Psd1 file.
          $manifestContent = $manifestContent.Replace(
            "'<FunctionsToExport>'", $(if ((Test-Path -Path $publicFunctionsPath) -and $publicFunctionNames.count -gt 0) { "'$($publicFunctionNames -join "',`n        '")'" }else { $null })
          ).Replace(
            "<ModuleVersion>", $BuildNumber
          ).Replace(
            "<ReleaseNotes>", $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ReleaseNotes'))
          ).Replace(
            "<Year>", ([Datetime]::Now.Year)
          )
          $manifestContent | Set-Content -Path $ModuleManifest
          if ((Get-ChildItem $outputModVerDir | Where-Object { $_.Name -eq "$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).psd1" }).BaseName -cne $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))) {
            "    Renaming manifest to correct casing"
            Rename-Item (Join-Path $outputModVerDir "$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).psd1") -NewName "$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).psd1" -Force
          }
          $Host.UI.WriteLine()
          "    Created compiled module at [$outputModDir]"
          "    Output version directory contents"
          Get-ChildItem $outputModVerDir | Format-Table -AutoSize
        } -Description 'Compiles module from source'

        Task Clean {
          $Host.UI.WriteLine();
          Write-Heading "CleanUp: Module '$ProjectName' env variables and previous build Output"
          if (Test-Path -Path $outputDir -PathType Container -ea Ignore) {
            Get-ChildItem -Path $outputDir -Recurse -Force | Remove-Item -Force -Recurse -Verbose:$false | Out-Null
            Write-Host "    Removed previous Output directory [$outputDir]" -F Green
          }
        } -Description 'Cleans module output directory'

        Task Test -Depends Compile {
          Write-Heading "Executing Script: ./Test-Module.ps1"
          $test_Script = [IO.FileInfo]::New([IO.Path]::Combine($ProjectRoot, 'Test-Module.ps1'))
          if (!$test_Script.Exists) {
            $_err_r = [System.Management.Automation.ErrorRecord]::new([System.IO.FileNotFoundException]::New($test_Script.FullName), 'CouldNotFindTestScript', 'ObjectNotFound', $test_Script.FullName)
            $(Get-Variable psake -Scope global -ValueOnly).error_message = $_err_r
            $Cmdlet.ThrowTerminatingError($_err_r)
          }
          Import-Module Pester -Verbose:$false -Force -ea Stop
          $origModulePath = $Env:PSModulePath
          Push-Location $ProjectRoot
          if ($Env:PSModulePath.split($pathSeperator) -notcontains $outputDir) {
            $Env:PSModulePath = ($outputDir + $pathSeperator + $origModulePath)
          }
          Remove-Module $ProjectName -ea SilentlyContinue -Verbose:$false
          if ([bool]([ScriptBlock]::Create('git rev-parse --is-inside-work-tree 2>$null').Invoke())) {
            Import-Module $outputModDir -Force -Verbose:$false
          }
          $Host.UI.WriteLine();
          $TestResults = & $test_Script
          Write-Host '    Pester invocation complete!' -ForegroundColor Green
          $TestResults | Format-List
          if ($TestResults.FailedCount -gt 0) {
            $(Get-Variable psake -Scope global -ValueOnly).error_message = [System.Management.Automation.ErrorRecord]::new([Exception]::new("One or more Pester tests failed!"), "PesterTestsFailed", 'OperationStopped', @{})
          }
          Pop-Location
          $Env:PSModulePath = $origModulePath
        } -Description 'Run Pester tests against compiled module'

        Task Deploy -Depends Test -Description 'Release new github version and Publish module to PSGallery' {
          if ([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildSystem') -eq 'VSTS' -or ($env:CI -eq "true" -and $env:GITHUB_RUN_ID)) {
            # Load the module, read the exported functions, update the psd1 FunctionsToExport
            $commParsed = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage') | Select-String -Pattern '\sv\d+\.\d+\.\d+\s'
            if ($commParsed) {
              $commitVer = $commParsed.Matches.Value.Trim().Replace('v', '')
            }
            $current_build_version = $CurrentVersion = (Get-Module $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).Version
            $Latest_Module_Verion = Get-LatestModuleVersion -Name ([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')) -Source PsGallery
            "Module Current version on the PSGallery: $Latest_Module_Verion"
            $galVerSplit = "$Latest_Module_Verion".Split('.')
            $nextGalVer = [System.Version](($galVerSplit[0..($galVerSplit.Count - 2)] -join '.') + '.' + ([int]$galVerSplit[-1] + 1))
            # Bump MODULE Version
            $versionToDeploy = switch ($true) {
              $($commitVer -and ([System.Version]$commitVer -lt $nextGalVer)) {
                Write-Host -f Yellow "Version in commit message is $commitVer, which is less than the next Gallery version and would result in an error. Possible duplicate deployment build, skipping module bump and negating deployment"
                Set-Env -Name ($env:RUN_ID + 'CommitMessage') -Value $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')).Replace('!deploy', '')
                $null
                break
              }
              $($commitVer -and ([System.Version]$commitVer -gt $nextGalVer)) {
                Write-Host -f Green "Module Bumped version: $commitVer [from commit message]"
                [System.Version]$commitVer
                break
              }
              $($CurrentVersion -ge $nextGalVer) {
                Write-Host -f Green "Module Bumped version: $CurrentVersion [from manifest]"
                $CurrentVersion
                break
              }
              $(([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')) -match '!hotfix') {
                Write-Host -f Green "Module Bumped version: $nextGalVer [commit message match '!hotfix']"
                $nextGalVer
                break
              }
              $(([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')) -match '!minor') {
                $minorVers = [System.Version]("{0}.{1}.{2}" -f $nextGalVer.Major, ([int]$nextGalVer.Minor + 1), 0)
                Write-Host -f Green "Module Bumped version: $minorVers [commit message match '!minor']"
                $minorVers
                break
              }
              $(([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')) -match '!major') {
                $majorVers = [System.Version]("{0}.{1}.{2}" -f ([int]$nextGalVer.Major + 1), 0, 0)
                Write-Host -f Green "Module Bumped version: $majorVers [commit message match '!major']"
                $majorVers
                break
              }
              Default {
                Write-Host -f Green "Module Bumped version: $nextGalVer [PSGallery next version]"
                $nextGalVer
              }
            }
            if (!$versionToDeploy) {
              Write-Host -f Yellow "No module version matched! Negating deployment to prevent errors"
              Set-Env -Name ($env:RUN_ID + 'CommitMessage') -Value $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')).Replace('!deploy', '')
            }
            try {
              [ValidateNotNullOrWhiteSpace()][string]$versionToDeploy = $versionToDeploy.ToString()
              $manifest = Import-PowerShellDataFile -Path $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'PSModuleManifest'))
              $latest_Github_release = Invoke-WebRequest "https://api.github.com/repos/chadnpc/$ProjectName/releases/latest" | ConvertFrom-Json
              $latest_Github_release = [PSCustomObject]@{
                name = $latest_Github_release.name
                ver  = [version]::new($latest_Github_release.tag_name.substring(1))
                url  = $latest_Github_release.html_url
              }
              $Is_Lower_PsGallery_Version = [version]$current_build_version -le $Latest_Module_Verion
              $should_Publish_ToPsGallery = ![string]::IsNullOrWhiteSpace($env:NUGETAPIKEY) -and !$Is_Lower_PsGallery_Version
              $Is_Lower_GitHub_Version = [version]$current_build_version -le $latest_Github_release.ver
              $should_Publish_GitHubRelease = ![string]::IsNullOrWhiteSpace($env:GitHubPAT) -and ($env:CI -eq "true" -and $env:GITHUB_RUN_ID) -and !$Is_Lower_GitHub_Version
              if ($should_Publish_ToPsGallery) {
                $manifestPath = Join-Path $outputModVerDir "$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).psd1"
                if (-not $manifest) {
                  $manifest = Import-PowerShellDataFile -Path $manifestPath
                }
                if ($manifest.ModuleVersion.ToString() -eq $versionToDeploy.ToString()) {
                  "    Manifest is already the expected version. Skipping manifest version update"
                } else {
                  "    Updating module version on manifest to [$versionToDeploy]"
                  Update-Metadata -Path $manifestPath -PropertyName ModuleVersion -Value $versionToDeploy -Verbose
                }
                Write-Host "    Publishing version [$versionToDeploy] to PSGallery..." -ForegroundColor Green
                Publish-Module -Path $outputModVerDir -NuGetApiKey $env:NUGETAPIKEY -Repository PSGallery -Verbose
                Write-Host "    Published to PsGallery successful!" -ForegroundColor Green
              } else {
                if ($Is_Lower_PsGallery_Version) { Write-Warning "SKIPPED Publishing. Module version $Latest_Module_Verion already exists on PsGallery!" }
                Write-Verbose "    SKIPPED Publish of version [$versionToDeploy] to PSGallery"
              }
              $commitId = $(try { git rev-parse --verify HEAD } catch { Write-Warning $_; $null });
              if ($should_Publish_GitHubRelease) {
                $ReleaseNotes = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ReleaseNotes')
                [ValidateNotNullOrWhiteSpace()][string]$ReleaseNotes = $ReleaseNotes
                "    Creating Release ZIP..."
                $ZipTmpPath = [System.IO.Path]::Combine($ProjectRoot, "$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).zip")
                if ([IO.File]::Exists($ZipTmpPath)) { Remove-Item $ZipTmpPath -Force -ea Ignore }
                Add-Type -Assembly System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::CreateFromDirectory($outputModDir, $ZipTmpPath)
                Write-Heading "    Publishing Release v$versionToDeploy @ commit Id [$($commitId)] to GitHub..."
                $ReleaseNotes += $(try { git log -1 --pretty=%B | Select-Object -Skip 2 } catch { Write-Warning $_; [string]::Empty }) -join "`n"
                $ReleaseNotes = $ReleaseNotes.Replace('<versionToDeploy>', $versionToDeploy)
                Set-Env -Name ('{0}{1}' -f $env:RUN_ID, 'ReleaseNotes') -Value $ReleaseNotes
                $gitHubParams = @{
                  VersionNumber    = $versionToDeploy
                  CommitId         = $commitId
                  ReleaseNotes     = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ReleaseNotes')
                  ArtifactPath     = $ZipTmpPath
                  GitHubUsername   = $(try { [string][uri]::new((git config --get remote.origin.url)).Segments[1].Replace('/', '') } catch { Write-Warning $_; $null })
                  GitHubRepository = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
                  GitHubApiKey     = $env:GitHubPAT
                  Draft            = $false
                }
                Publish-GitHubRelease @gitHubParams
                Write-Heading "    Github release created successful!"
              } else {
                if ($Is_Lower_GitHub_Version) { Write-Warning "SKIPPED Releasing. Module version $current_build_version already exists on Github!" }
                Write-Verbose "    SKIPPED GitHub Release v$($versionToDeploy) @ commit Id [$($commitId)] to GitHub"
              }
            } catch {
              $_ | Format-List * -Force
              $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new($_.Exception, $_.FullyQualifiedErrorId, $_.CategoryInfo, $_.TargetObject))
            }
          } else {
            Write-Host -f Magenta "UNKNOWN Build system"
          }
        }
      }
    )
    $psd1 = [IO.Path]::Combine($Path, "$([IO.DirectoryInfo]::new($Path).BaseName).psd1")
    if ([IO.File]::Exists($psd1)) {
      $data = [PsObject]([scriptblock]::Create("$([IO.File]::ReadAllText($psd1))").Invoke() | Select-Object *)
      $build_requirements = $data.RequiredModules + $build_requirements | Select-Object -Unique
    }
    function Test-NetworkConnectivity {
      #.SYNOPSIS
      #  Pretty straight-forward fxn to test if a device is offline or not.
      #.DESCRIPTION
      #  Attempts to connect to the target multiple times, checking for successful connection status
      #.EXAMPLE
      #  Test-NetworkConnectivity fast.com
      [CmdletBinding()][OutputType([bool])]
      param (
        # The hostname or IP address to test connectivity to
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateNotNullOrWhiteSpace()]
        [string]$Target = "www.github.com",

        [Parameter(Mandatory = $false, Position = 1)]
        [int]$MaxAttempts = 5,

        [Parameter(Mandatory = $false, Position = 2)]
        [int]$TimeoutSeconds = 1
      )
      # Define successful status values
      $a = 1; $ic = $false; $SS = [System.Net.NetworkInformation.IPStatus[]]@( "Success", "TtlExpired" )
      while ($a -le $MaxAttempts -and !$ic) {
        try {
          Write-Verbose "Test connection - Attempt [$a/$MaxAttempts]"
          $cr = Test-Connection -TargetName $Target -Count 1 -TimeoutSeconds $TimeoutSeconds -ea Ignore
          $ic = $SS.Contains($cr.Status)
          $cr | Out-String | Write-Host -f (@{ 1 = "Green"; 0 = "Red" }[[int]$ic]);
        } catch {
          Write-Verbose "Exception occurred on attempt $a : $($_.Exception.Message)"
        }
        if ($a -lt $MaxAttempts) { Start-Sleep -Milliseconds 600 }; $a++
      }
      return $ic
    }
  }
  Process {
    #region    packagefeed
    # .DESCRIPTION
    #  This will fix any crazy errors you might have when installing modules:
    $PackageProviders = Get-PackageProvider -ListAvailable -ea Ignore -Verbose:$false
      ("NuGet", "PowerShellGet") | ForEach-Object {
      if (!$PackageProviders.Name.Contains($_)) { Install-PackageProvider -Name $_ -Force }
      Get-PackageProvider -Name $_ -ForceBootstrap -Verbose:$false
    }
    if ($null -eq (Get-PSRepository -Name PSGallery -ea Ignore -Verbose:$false)) {
      Unregister-PSRepository -Name PSGallery -Verbose:$false -ea Ignore
      Register-PSRepository -Default -InstallationPolicy Trusted
    }
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -Verbose:$false
    }
    #endregion packagefeed
    #region    buildrequirements
    Write-Host "Resolve build requirements: [$($build_requirements -join ', ')]" -f Green
    $IsGithubRun = ![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))
    $IsConnected = $IsGithubRun ? $true : $(Test-NetworkConnectivity); $InstalledModules = $(if (!$IsConnected) { (Get-Module -Verbose:$false) + (Get-InstalledModule -Verbose:$false) | Select-Object -Unique -ExpandProperty Name } else { @() })
    $L = (($build_requirements | Select-Object @{l = 'L'; e = { $_.Length } }).L | Sort-Object -Descending)[0]
    foreach ($name in $build_requirements) {
      try {
        if ($IsConnected) {
          [void][ThreadRunner]::Run(" [+] Install-Module -Name $name", { param([string]$N) Install-Module -Name $N -Verbose:$false -ea Stop }, ($name))
        } elseif ($InstalledModules -contains $name) {
          Write-Host " [+] Module $name$(' '* $($L - $name.Length))was already installed" -f Green
        } else {
          throw [System.Management.Automation.ItemNotFoundException]::new("Module $name is not installed.")
        }
      } catch {
        $PSCmdlet.ThrowTerminatingError($_)
      }
    }
    $psds = (Get-Module -Name $build_requirements -ListAvailable -Verbose:$false).Path | Sort-Object -Unique { Split-Path $_ -Leaf }
    $psds | Import-Module -Verbose:$false -ea Stop
    #endregion buildrequirements
    try {
      $Psake_BuildFile = New-Item $([IO.Path]::GetTempFileName().Replace('.tmp', '.ps1'))
      Set-Content -Path $Psake_BuildFile -Value $script:PSake_ScriptBlock.ToString().Replace('<build_requirements>', [string]('@("' + ($build_requirements -join '", "') + '")')) | Out-Null
      if ($Help.IsPresent) {
        Write-Heading "Getting help"; Get-PSakeScriptTasks -BuildFile $Psake_BuildFile.FullName | Sort-Object -Property Name | Format-Table -Property Name, Description, Alias, DependsOn;
        return
      };
      [Environment]::SetEnvironmentVariable('IsAC', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
      [Environment]::SetEnvironmentVariable('IsCI', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('TF_BUILD'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
      [Environment]::SetEnvironmentVariable('RUN_ID', $(if ([bool][int]$env:IsAC -or $env:CI -eq "true") { [Environment]::GetEnvironmentVariable('GITHUB_RUN_ID') }else { [Guid]::NewGuid().Guid.substring(0, 21).replace('-', [string]::Join('', (0..9 | Get-Random -Count 1))) + '_' }), [System.EnvironmentVariableTarget]::Process);
      Set-BuildVariables $Path $env:RUN_ID
      Write-Heading "Invoking psake with task: [ $($Task -join ', ') ]"
      if ($Task -contains 'TestOnly') {
        Set-Variable -Name ExcludeTag -Scope global -Value @('Module')
      } else {
        Set-Variable -Name ExcludeTag -Scope global -Value $null
      }
      $psakeParams = @{
        nologo    = $true
        buildFile = $Psake_BuildFile.FullName
        taskList  = $Task
      }
      Invoke-psake @psakeParams @verbose
    } catch {
      $psake.error_message = $_
      $PSCmdlet.ThrowTerminatingError($_)
    } finally {
      $psake.build_success = $null -eq $psake.error_message
      $LocalPSRepo = [IO.Path]::Combine([environment]::GetEnvironmentVariable("HOME"), 'LocalPSRepo'); $Host.UI.WriteLine()
      Remove-Item $Psake_BuildFile -Force -ea Ignore -Verbose:$false | Out-Null
      if ($psake.build_success) {
        Write-Heading "Create a Local repository"
        if (!(Get-Variable -Name IsWindows -ea Ignore) -or $(Get-Variable IsWindows -ValueOnly)) {
          $LocalPSRepo = [IO.Path]::Combine([environment]::GetEnvironmentVariable("UserProfile"), 'LocalPSRepo')
        }; if (!(Test-Path -Path $LocalPSRepo -PathType Container -ea Ignore)) { New-Directory -Path $LocalPSRepo | Out-Null }
        Register-PSRepository LocalPSRepo -SourceLocation $LocalPSRepo -PublishLocation $LocalPSRepo -InstallationPolicy Trusted -Verbose:$false -ea Ignore;
        Register-PackageSource -Name LocalPsRepo -Location $LocalPSRepo -Trusted -ProviderName Bootstrap -ea Ignore
        Write-Verbose "Verify that the new repository was created successfully"
        if ($null -ne (Get-PSRepository LocalPSRepo -Verbose:$false -ea Ignore)) {
          $ModuleName = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
          $BuildNumber = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildNumber')
          $ModulePath = [IO.Path]::Combine($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput')), $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')), $BuildNumber)
          # Publish To LocalRepo
          $ModulePackage = [IO.Path]::Combine($LocalPSRepo, "${ModuleName}.${BuildNumber}.nupkg")
          if ([IO.File]::Exists($ModulePackage)) {
            Remove-Item -Path $ModulePackage -Force -ea 'SilentlyContinue'
          }
          Write-Heading "Publish to Local PsRepository"
          $RequiredModules = Read-ModuleData -File ([IO.Path]::Combine($ModulePath, "$([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')).psd1")) -Property RequiredModules -Verbose:$false
          foreach ($Module in $RequiredModules) {
            $mdPath = (Get-Module $Module -ListAvailable -Verbose:$false)[0].Path | Split-Path
            Write-Verbose "Publish RequiredModule $Module ..."
            Publish-Module -Path $mdPath -Repository LocalPSRepo -Verbose:$false -ea Ignore
          }
          Publish-Module -Path $ModulePath -Repository LocalPSRepo -Verbose:$false
          Install-Module $ModuleName -Repository LocalPSRepo -Force -Verbose:$false
          if ($Import.IsPresent -and $(Get-Variable psake -Scope global -ValueOnly).build_success) {
            Write-Heading "Import $ModuleName to local scope"
            # Import-Module $([IO.Path]::Combine([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput'), $ModuleName))
            Import-Module $ModuleName -Verbose:$false
          }
        } else {
          $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new([System.Exception]::New('Failed to create LocalPsRepo', [System.IO.DirectoryNotFoundException]::New($LocalPSRepo)), 'LocalPsRepo_NOT_FOUND', 'ObjectNotFound', $LocalPSRepo))
        }
      }
      Write-EnvironmentSummary "Build $($psake.build_success ? "complete" : "Failed")"
      if (![bool][int]$env:IsAC -or $Task -contains 'Clean') {
        Write-Heading "CleanUp: Remove '$ModuleName' env variables and clean LocalPSRepo"
        if (![string]::IsNullOrWhiteSpace($env:RUN_ID)) {
          $OldEnvNames = [Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like "$env:RUN_ID*" }
          if ($OldEnvNames.Count -gt 0) {
            foreach ($Name in $OldEnvNames) {
              Write-BuildLog "Remove env variable $Name"
              [Environment]::SetEnvironmentVariable($Name, $null)
            }
          } else {
            Write-BuildLog "No env variables to remove; Move on ...`n"
          }
        } else {
          Write-Warning "Invalid RUN_ID! can't remove env variables.`n"
        }
        if ($ModuleName) { Uninstall-Module $ModuleName -MinimumVersion $BuildNumber -Force -ea Ignore }
        if ([IO.Directory]::Exists($LocalPSRepo)) {
          if ($null -ne (Get-PSRepository -Name 'LocalPSRepo' -ea Ignore -Verbose:$false)) {
            Invoke-Command -ScriptBlock ([ScriptBlock]::Create("Unregister-PSRepository -Name 'LocalPSRepo' -Verbose:`$false -ea Ignore"))
          }; Remove-Item $LocalPSRepo -Verbose:$false -Force -Recurse -ea Ignore
        }
        [Environment]::SetEnvironmentVariable('RUN_ID', $null)
      }
    }
  }
  end {
    return ([int](!$psake.build_success))
  }
}
