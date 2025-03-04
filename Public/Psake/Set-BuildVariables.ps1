function Set-BuildVariables {
  # .SYNOPSIS
  #   Creates build env variables with a Prefix.
  # .DESCRIPTION
  #   Sets unique build env variables for easy Cleaning and not to pollute Last Builds's Env~ variables.
  #   Good for comparing variables when last build fails
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    # Project root.
    [Parameter(Mandatory = $false, Position = 0)]
    [ValidateScript({
        $p = Resolve-Path $_ -ea Ignore
        if ((Test-Path -Path $p -PathType Container -ea Ignore)) {
          return $true
        } else {
          throw [System.ArgumentException]::new("directory '$_' does not exist.", 'Path')
        }
      }
    )]
    [Alias('root')][string]
    $Path = $PSScriptRoot,

    [Parameter(Mandatory = $false, Position = 1)]
    [ValidatePattern('\w*')][Alias('RunId')][String]
    $Prefix = $env:RUN_ID,

    # Data from a .pds1 file
    [Parameter(Mandatory = $false, Position = 2)]
    [ValidateNotNullOrEmpty()][PsObject]
    $Data
  )

  Process {
    if (![IO.Directory]::Exists($Path)) { [string]$Path = Resolve-Path $Path -ea Stop }
    if (!$PSBoundParameters.ContainsKey("Data")) { $Data = Read-ModuleData -Path $Path }; $Version = $Data.ModuleVersion
    if ($null -eq $Version) { throw [System.ArgumentNullException]::new('version', "Please make sure localizedData.ModuleVersion is not null.") }
    if (![bool][int]$env:IsAC) {
      $LocEnvFile = [IO.FileInfo]::New([IO.Path]::GetFullPath([IO.Path]::Combine($Path, '.env')))
      if (!$LocEnvFile.Exists) {
        New-Item -Path $LocEnvFile.FullName -ItemType File -ErrorAction Stop | Out-Null
        Write-BuildLog "Created a new .env file"
      }
      # Set all Default/Preset Env: variables from the .env
      Set-Env -source $LocEnvFile -Scope Process
      if (![string]::IsNullOrWhiteSpace($env:LAST_BUILD_ID)) {
        Set-Env -Name LAST_BUILD_ID -Value $Prefix -OutFile $LocEnvFile
        Get-Item $LocEnvFile -Force | ForEach-Object { $_.Attributes = $_.Attributes -bor "Hidden" }
        if ($PSCmdlet.ShouldProcess("$Env:ComputerName", "Clean Last Builds's Env~ variables")) {
          Invoke-Command $Clean_EnvBuildvariables -ArgumentList $env:LAST_BUILD_ID
        }
      }
    }
    Write-Heading "Set Build Variables for Version: $Version"
    Set-Env -Name ('{0}{1}' -f $Prefix, 'BuildStart') -Value $(Get-Date -Format o)
    Set-Env -Name ('{0}{1}' -f $Prefix, 'BuildScriptPath') -Value $Path
    Set-Env -Name ('{0}{1}' -f $Prefix, 'BuildSystem') -Value $(if ([bool][int]$env:IsCI -or ($Env:BUILD_BUILDURI -like 'vstfs:*')) { "VSTS" } else { [System.Environment]::MachineName })
    Set-Env -Name ('{0}{1}' -f $Prefix, 'ProjectPath') -Value $(if ([bool][int]$env:IsCI) { $Env:SYSTEM_DEFAULTWORKINGDIRECTORY } else { $Path })
    Set-Env -Name ('{0}{1}' -f $Prefix, 'BranchName') -Value $(if ([bool][int]$env:IsCI) { $Env:BUILD_SOURCEBRANCHNAME } else { Push-Location $Path; $h = [string]$(try { git rev-parse --abbrev-ref HEAD } catch { [string]::Empty }).Trim(); Pop-Location; $h })
    Set-Env -Name ('{0}{1}' -f $Prefix, 'CommitMessage') -Value $(if ([bool][int]$env:IsCI) { $Env:BUILD_SOURCEVERSIONMESSAGE } else { Push-Location $Path; $m = [String]$(try { git log --format=%B -n 1 } catch { [string]::Empty }).Trim(); Pop-Location; $m })
    Set-Env -Name ('{0}{1}' -f $Prefix, 'BuildNumber') -Value $(if ([bool][int]$env:IsCI) { $Env:BUILD_BUILDNUMBER } else { $(if ([string]::IsNullOrWhiteSpace($Version)) { [version]::new('1.0.0.1') } else { $Version }) })
    Set-Variable -Name BuildNumber -Value ([Environment]::GetEnvironmentVariable($Prefix + 'BuildNumber')) -Scope Local -Force
    Set-Env -Name ('{0}{1}' -f $Prefix, 'BuildOutput') -Value $([IO.path]::Combine($Path, "BuildOutput"))
    Set-Variable -Name BuildOutput -Value ([Environment]::GetEnvironmentVariable($Prefix + 'BuildOutput')) -Scope Local -Force
    Set-Env -Name ('{0}{1}' -f $Prefix, 'ProjectName') -Value ($Data.ModuleName)
    Set-Variable -Name ProjectName -Value ([Environment]::GetEnvironmentVariable($Prefix + 'ProjectName')) -Scope Local -Force
    Set-Env -Name ('{0}{1}' -f $Prefix, 'PSModulePath') -Value $([IO.path]::Combine($BuildOutput, $ProjectName, $BuildNumber))
    Set-Env -Name ('{0}{1}' -f $Prefix, 'PSModuleManifest') -Value $([IO.path]::Combine($BuildOutput, $ProjectName, $BuildNumber, "$ProjectName.psd1"))
    Set-Env -Name ('{0}{1}' -f $Prefix, 'ModulePath') -Value $(if (![string]::IsNullOrWhiteSpace($Env:PSModuleManifest)) { [IO.Path]::GetDirectoryName($Env:PSModuleManifest) } else { [IO.Path]::GetDirectoryName($BuildOutput) })
    Set-Env -Name ('{0}{1}' -f $Prefix, 'ReleaseNotes') -Value ($data.ReleaseNotes)
  }
}