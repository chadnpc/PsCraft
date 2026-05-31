function Build-Module {
  # .SYNOPSIS
  #    Module buildScript
  # .DESCRIPTION
  #    A custom Psake buildScript for any module that was created by PsCraft.
  #    Core logic lives in [BuildOrchestrator]. This cmdlet is a thin parameter
  #    wrapper that delegates everything to the class.
  # .EXAMPLE
  #    Build-Module                # Compile + Test
  #    Build-Module Test
  #    Build-Module Deploy
  # .LINK
  #    https://github.com/chadnpc/PsCraft/blob/main/public/Build-Module.ps1
  [cmdletbinding(DefaultParameterSetName = 'task')]
  param(
    [parameter(Mandatory = $false, Position = 0, ParameterSetName = 'task')]
    [ValidateScript({
        $task_seq = [string[]]$_; $IsValid = $true
        $Tasks = @('Clean', 'Compile', 'Test', 'Deploy')
        foreach ($name in $task_seq) { $IsValid = $IsValid -and ($name -in $Tasks) }
        if ($IsValid) { return $true }
        throw [System.ArgumentException]::new('Task', "ValidSet: $($Tasks -join ', ').")
      })][ValidateNotNullOrEmpty()][Alias('t')]
    [string[]]$Task = 'Test',

    [Parameter(Mandatory = $false, Position = 1, ParameterSetName = 'task')]
    [ValidateScript({
        if (Test-Path -Path $_ -PathType Container -ea Ignore) { return $true }
        throw [System.ArgumentException]::new('Path', "Path: $_ is not a valid directory.")
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

  begin {
    #Requires -Psedition Core
    $script:build_requirements = ($RequiredModules + @(
        'PackageManagement', 'PSScriptAnalyzer',
        'cliHelper.env', 'cliHelper.core',
        'PsCraft', 'Pester', 'psake')
    ) | Select-Object -Unique

    # Build the PSake scriptblock (same logic as before, stored on the class)
    [BuildOrchestrator]::PSakeScriptBlock = [scriptblock]::Create({
        Properties {
          $taskList        = $Task
          $Cmdlet          = $PSCmdlet
          $ProjectName     = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
          $BuildNumber     = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildNumber')
          $ProjectRoot     = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectPath')
          $outputDir       = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput')
          $PSVersion       = $PSVersionTable.PSVersion.ToString()
          $outputModDir    = [IO.path]::Combine([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput'), $ProjectName)
          $tests           = [IO.Path]::Combine($projectRoot, 'Tests')
          $lines           = ('-' * 70)
          $TestFile        = "TestResults_PS${PSVersion}_$(Get-Date -UFormat %Y%m%d-%H%M%S).xml"
          $outputModVerDir = [IO.path]::Combine([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput'), $ProjectName, $BuildNumber)
          $PathSeperator   = [IO.Path]::PathSeparator
          $DirSeperator    = [IO.Path]::DirectorySeparatorChar
          $buildrequirements = <build_requirements>
          $null = @($taskList, $Cmdlet, $tests, $TestFile, $ProjectRoot, $outputDir, $outputModDir, $outputModVerDir, $lines, $DirSeperator, $PathSeperator, $buildrequirements)
        }

        Task default -Depends Test

        Task Compile -Depends Clean {
          $security_protocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::SystemDefault
          if ([Net.SecurityProtocolType].GetMember('Tls12').Count -gt 0) { $security_protocol = $security_protocol -bor [Net.SecurityProtocolType]::Tls12 }
          [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]$security_protocol
          $buildrequirements.ForEach({ Import-Module $_ -Verbose:$false -ea Stop })
          [AnsiConsole]::Console.WriteLine('')
          [BuildLog]::WriteEnvironmentSummary("Initialize [$ProjectName] build environment")
          Set-Location $ProjectRoot
          [BuildLog]::InvokeCommandWithLog({
              $script:DefaultParameterValues = @{
                '*-Module:Verbose'           = $false
                'Import-Module:ErrorAction'  = 'Stop'
                'Import-Module:Force'        = $true
                'Import-Module:Verbose'      = $false
                'Install-Module:ErrorAction' = 'Stop'
                'Install-Module:Scope'       = 'CurrentUser'
                'Install-Module:Verbose'     = $false
              }
            })
          [BuildLog]::WriteHeading('Prepare package feeds')
          if ($null -eq (Get-PSRepository -Name PSGallery -ea Ignore)) {
            Unregister-PSRepository -Name PSGallery -Verbose:$false -ea Ignore
            Register-PSRepository -Default -InstallationPolicy Trusted
          }
          if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
            [BuildLog]::InvokeCommandWithLog({ Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -Verbose:$false })
          }
          [BuildLog]::InvokeCommandWithLog({ Get-PackageProvider -Name Nuget -ForceBootstrap -Verbose:$false })
          if (!(Get-PackageProvider -Name Nuget)) {
            [BuildLog]::InvokeCommandWithLog({ Install-PackageProvider -Name NuGet -Force | Out-Null })
          }
          $build_sys  = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildSystem')
          $lastCommit = $(try { git log -1 --pretty=%B } catch { [string]::Empty })
          [BuildLog]::Write("Current build system is $build_sys")
          [BuildLog]::WriteHeading('Finalizing build Prerequisites and Resolving dependencies ...')

          if ($build_sys -eq 'VSTS' -or ($env:CI -eq 'true' -and $env:GITHUB_RUN_ID)) {
            if ($Task -contains 'Deploy') {
              $MSG = "Task is 'Deploy' and conditions for deployment are:`n" +
              "    + GitHub API key is not null       : $(![string]::IsNullOrWhiteSpace($env:GitHubPAT))`n" +
              "    + Current branch is main           : $(($env:GITHUB_REF -replace 'refs/heads/') -eq 'main')`n" +
              "    + Source is not a pull request     : $($env:GITHUB_EVENT_NAME -ne 'pull_request') [$env:GITHUB_EVENT_NAME]`n" +
              "    + Commit message matches '!deploy' : $($lastCommit -match '!deploy') [$lastCommit]`n" +
              "    + NuGet API key is not null        : $(![string]::IsNullOrWhiteSpace($env:NUGETAPIKEY))`n"
              if ($PSVersionTable.PSVersion.Major -lt 5 -or [string]::IsNullOrWhiteSpace($env:NUGETAPIKEY) -or [string]::IsNullOrWhiteSpace($env:GitHubPAT)) {
                $MSG = $MSG.Replace('and conditions for deployment are:', 'but conditions are not correct for deployment.')
                try { [AnsiConsole]::Console.MarkupLine("[yellow]$([AnsiConsole]::EscapeMarkup($MSG))[/]") } catch { Write-Host $MSG -f Yellow }
                if (!($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')) -match '!deploy' -and $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BranchName')) -eq 'main') -and !$script:ForceDeploy) {
                  try { [AnsiConsole]::Console.MarkupLine('[yellow]Skipping Psake for this job![/]') } catch { Write-Host 'Skipping Psake for this job!' -f Yellow }
                  return
                }
              } else {
                try { [AnsiConsole]::Console.MarkupLine("[green]$([AnsiConsole]::EscapeMarkup($MSG))[/]") } catch { Write-Host $MSG -f Green }
              }
            }
          }

          New-Item -Path $outputModVerDir -ItemType Directory -Force -ea SilentlyContinue | Out-Null
          $ModuleManifest     = [IO.FileInfo]::New([Environment]::GetEnvironmentVariable($env:RUN_ID + 'PSModuleManifest'))
          [BuildLog]::Write("Add Module files ...`nRef: https://aka.ms/nuget/authoring-best-practices")

          # Progress bar for file copy
          $filesToCopy = @('en-US','Private','Public','LICENSE','README.md',$ModuleManifest.Name,"$ProjectName.psm1")
          $destDir     = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'PSModulePath')
          try {
            $progress = [Progress]::new([AnsiConsole]::Console)
            $progress.RefreshRateMs = 80
            $progress.Start([Action[ProgressContext]] {
                param($ctx)
                $task = $ctx.AddTask('[green]Copying module files[/]', [ProgressTaskSettings]::new())
                $task.MaxValue = $filesToCopy.Count
                foreach ($item in $filesToCopy) {
                  $p = [IO.Path]::Combine([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildScriptPath'), $item)
                  if (Test-Path -Path $p -ea Ignore) { Copy-Item -Recurse -Path $p -Destination $destDir }
                  $task.Increment(1)
                }
              })
          } catch {
            # fallback
            try {
              foreach ($item in $filesToCopy) {
                $p = [IO.Path]::Combine([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildScriptPath'), $item)
                if (Test-Path -Path $p -ea Ignore) { Copy-Item -Recurse -Path $p -Destination $destDir }
              }
            } catch {
              $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new($_.Exception, $_.FullyQualifiedErrorId, $_.CategoryInfo, $_.TargetObject))
            }
          }

          if (!$ModuleManifest.Exists) {
            $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new([IO.FileNotFoundException]::New('Could Not Create Module Manifest!'), 'CouldNotCreateModuleManifest', 'ObjectNotFound', $ModuleManifest))
          }
          $publicFunctionsPath = [IO.Path]::Combine([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectPath'), 'Public')
          $publicFunctionNames = Get-ChildItem -Path $publicFunctionsPath -Filter '*.ps1' | Select-Object -ExpandProperty BaseName
          $manifestContent     = Get-Content -Path $ModuleManifest -Raw
          $manifestContent = $manifestContent.Replace(
            "'<FunctionsToExport>'", $(if ((Test-Path -Path $publicFunctionsPath) -and $publicFunctionNames.count -gt 0) { "'$($publicFunctionNames -join "',`n        '")'" } else { $null })
          ).Replace('<ModuleVersion>', $BuildNumber
          ).Replace('<ReleaseNotes>', $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ReleaseNotes'))
          ).Replace('<Year>', ([Datetime]::Now.Year))
          $manifestContent | Set-Content -Path $ModuleManifest
          if ((Get-ChildItem $outputModVerDir | Where-Object { $_.Name -eq "$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).psd1" }).BaseName -cne $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))) {
            Rename-Item (Join-Path $outputModVerDir "$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).psd1") -NewName "$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).psd1" -Force
          }
          [AnsiConsole]::Console.WriteLine('')
          [BuildLog]::Write("Created compiled module at [$outputModDir]")
          try {
            $table = [Table]::new()
            [void]$table.AddColumn([TableColumn]::new('Name'))
            [void]$table.AddColumn([TableColumn]::new('Length'))
            foreach ($f in (Get-ChildItem $outputModVerDir)) {
              [void]$table.AddRow(@($f.Name, "$($f.Length)"))
            }
            [AnsiConsole]::Console.Write($table)
          } catch { Get-ChildItem $outputModVerDir | Format-Table -AutoSize }
        } -Description 'Compiles module from source'

        Task Clean {
          [AnsiConsole]::Console.WriteLine('')
          [BuildLog]::WriteHeading("CleanUp: Module '$ProjectName' env variables and previous build Output")
          if (Test-Path -Path $outputDir -PathType Container -ea Ignore) {
            Get-ChildItem -Path $outputDir -Recurse -Force | Remove-Item -Force -Recurse -Verbose:$false | Out-Null
            try { [AnsiConsole]::Console.MarkupLine("[green]    Removed previous Output directory [$([AnsiConsole]::EscapeMarkup($outputDir))][/]") } catch { Write-Host "    Removed previous Output directory [$outputDir]" -F Green }
          }
        } -Description 'Cleans module output directory'

        Task Test -Depends Compile {
          [BuildLog]::WriteHeading('Executing Script: ./Test-Module.ps1')
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
          [AnsiConsole]::Console.WriteLine('')
          $TestResults = & $test_Script
          try { [AnsiConsole]::Console.MarkupLine('[bold green]    Pester invocation complete![/]') } catch { Write-Host '    Pester invocation complete!' -ForegroundColor Green }
          $TestResults | Format-List
          if ($TestResults.FailedCount -gt 0) {
            $(Get-Variable psake -Scope global -ValueOnly).error_message = [System.Management.Automation.ErrorRecord]::new([Exception]::new('One or more Pester tests failed!'), 'PesterTestsFailed', 'OperationStopped', @{})
          }
          Pop-Location
          $Env:PSModulePath = $origModulePath
        } -Description 'Run Pester tests against compiled module'

        Task Deploy -Depends Test -Description 'Release new github version and Publish module to PSGallery' {
          if ([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildSystem') -eq 'VSTS' -or ($env:CI -eq 'true' -and $env:GITHUB_RUN_ID)) {
            $commParsed = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage') | Select-String -Pattern '\sv\d+\.\d+\.\d+\s'
            if ($commParsed) { $commitVer = $commParsed.Matches.Value.Trim().Replace('v', '') }
            $current_build_version = (Get-Module $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).Version
            $Latest_Module_Verion  = Get-LatestModuleVersion -Name ([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')) -Source PsGallery
            $galVerSplit  = "$Latest_Module_Verion".Split('.')
            $nextGalVer   = [System.Version](($galVerSplit[0..($galVerSplit.Count - 2)] -join '.') + '.' + ([int]$galVerSplit[-1] + 1))
            $versionToDeploy = switch ($true) {
              $($commitVer -and ([System.Version]$commitVer -lt $nextGalVer)) {
                Set-Env -Name ($env:RUN_ID + 'CommitMessage') -Value $([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')).Replace('!deploy', '')
                $null; break
              }
              $($commitVer -and ([System.Version]$commitVer -gt $nextGalVer)) { [System.Version]$commitVer; break }
              $($current_build_version -ge $nextGalVer)                        { $current_build_version; break }
              $(([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')) -match '!hotfix') { $nextGalVer; break }
              $(([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')) -match '!minor') {
                [System.Version]("{0}.{1}.{2}" -f $nextGalVer.Major, ([int]$nextGalVer.Minor + 1), 0); break
              }
              $(([Environment]::GetEnvironmentVariable($env:RUN_ID + 'CommitMessage')) -match '!major') {
                [System.Version]("{0}.{1}.{2}" -f ([int]$nextGalVer.Major + 1), 0, 0); break
              }
              default { $nextGalVer }
            }
            if (!$versionToDeploy) {
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
              $Is_Lower_PsGallery_Version  = [version]$current_build_version -le $Latest_Module_Verion
              $should_Publish_ToPsGallery  = ![string]::IsNullOrWhiteSpace($env:NUGETAPIKEY) -and !$Is_Lower_PsGallery_Version
              $Is_Lower_GitHub_Version     = [version]$current_build_version -le $latest_Github_release.ver
              $should_Publish_GitHubRelease = ![string]::IsNullOrWhiteSpace($env:GitHubPAT) -and ($env:CI -eq 'true' -and $env:GITHUB_RUN_ID) -and !$Is_Lower_GitHub_Version
              if ($should_Publish_ToPsGallery) {
                $manifestPath = Join-Path $outputModVerDir "$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).psd1"
                if (!$manifest) { $manifest = Import-PowerShellDataFile -Path $manifestPath }
                if ($manifest.ModuleVersion.ToString() -ne $versionToDeploy.ToString()) {
                  Update-Metadata -Path $manifestPath -PropertyName ModuleVersion -Value $versionToDeploy -Verbose
                }
                try { [AnsiConsole]::Console.MarkupLine("[green]    Publishing version [$versionToDeploy] to PSGallery...[/]") } catch { Write-Host "    Publishing version [$versionToDeploy] to PSGallery..." -ForegroundColor Green }
                Publish-Module -Path $outputModVerDir -NuGetApiKey $env:NUGETAPIKEY -Repository PSGallery -Verbose
                try { [AnsiConsole]::Console.MarkupLine('[green]    Published to PsGallery successful![/]') } catch { Write-Host '    Published to PsGallery successful!' -ForegroundColor Green }
              }
              $commitId = $(try { git rev-parse --verify HEAD } catch { $null })
              if ($should_Publish_GitHubRelease) {
                $ReleaseNotes = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ReleaseNotes')
                [ValidateNotNullOrWhiteSpace()][string]$ReleaseNotes = $ReleaseNotes
                $ZipTmpPath = [System.IO.Path]::Combine($ProjectRoot, "$($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName'))).zip")
                if ([IO.File]::Exists($ZipTmpPath)) { Remove-Item $ZipTmpPath -Force -ea Ignore }
                Add-Type -Assembly System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::CreateFromDirectory($outputModDir, $ZipTmpPath)
                [BuildLog]::WriteHeading("Publishing Release v$versionToDeploy @ commit [$commitId] to GitHub...")
                $ReleaseNotes += $(try { git log -1 --pretty=%B | Select-Object -Skip 2 } catch { [string]::Empty }) -join "`n"
                $ReleaseNotes = $ReleaseNotes.Replace('<versionToDeploy>', $versionToDeploy)
                Set-Env -Name ('{0}{1}' -f $env:RUN_ID, 'ReleaseNotes') -Value $ReleaseNotes
                $gitHubParams = @{
                  VersionNumber    = $versionToDeploy
                  CommitId         = $commitId
                  ReleaseNotes     = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ReleaseNotes')
                  ArtifactPath     = $ZipTmpPath
                  GitHubUsername   = $(try { [string][uri]::new((git config --get remote.origin.url)).Segments[1].Replace('/', '') } catch { $null })
                  GitHubRepository = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
                  GitHubApiKey     = $env:GitHubPAT
                  Draft            = $false
                }
                Publish-GitHubRelease @gitHubParams
                [BuildLog]::WriteHeading('Github release created successfully!')
              }
            } catch {
              $_ | Format-List * -Force
              $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new($_.Exception, $_.FullyQualifiedErrorId, $_.CategoryInfo, $_.TargetObject))
            }
          } else {
            try { [AnsiConsole]::Console.MarkupLine('[magenta]UNKNOWN Build system[/]') } catch { Write-Host 'UNKNOWN Build system' -f Magenta }
          }
        }
      }.ToString())

    $orchestrator = [BuildOrchestrator]::new($Path, $Task, $script:build_requirements, $PSCmdlet)
  }

  process {
    [BuildOrchestrator]::ShowBanner()
    $orchestrator.PreparePackageFeeds()
    $orchestrator.ResolveBuildRequirements()
    if ($Help.IsPresent) {
      $tmpFile = New-Item $([IO.Path]::GetTempFileName().Replace('.tmp', '.ps1'))
      Set-Content -Path $tmpFile -Value [BuildOrchestrator]::PSakeScriptBlock.ToString().Replace('<build_requirements>', '@()') | Out-Null
      $orchestrator.ShowHelp($tmpFile.FullName)
      Remove-Item $tmpFile -Force -ea Ignore
      return
    }
    $exitCode = $orchestrator.Run($Task)
  }

  end {
    $success = $null -eq $psake.error_message
    $psake.build_success = $success
    $orchestrator.Finalize($success)
    if ($Import.IsPresent -and $success) {
      $ModuleName = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
      [BuildLog]::WriteHeading("Import $ModuleName to local scope")
      Import-Module $ModuleName -Verbose:$false
    }
    return ([int](!$success))
  }
}
