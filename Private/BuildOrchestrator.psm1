using namespace System.IO
using namespace System.Net
using namespace System.Management.Automation
using namespace System.Collections.Generic

# .SYNOPSIS
#  BuildOrchestrator — core build logic extracted from Build-Module.ps1.
#  Inherits ModuleManager for module-discovery utilities.
class BuildOrchestrator : ModuleManager {
  [string[]]  $TaskList
  [string]    $Path
  [string[]]  $RequiredModules
  [PSCmdlet]  $Cmdlet
  static [scriptblock] $PSakeScriptBlock = $null

  BuildOrchestrator([string]$path, [string[]]$tasks, [string[]]$requiredModules, [PSCmdlet]$cmdlet) {
    $this.Path = $path
    $this.TaskList = $tasks
    $this.RequiredModules = $requiredModules
    $this.Cmdlet = $cmdlet
  }

  # ── Banner ──────────────────────────────────────────────────────────────────
  static [void] ShowBanner() {
    try {
      $fig = [FigletText]::new([FigletFont]'DEFAULT_3D', 'PsCraft')
      [AnsiConsole]::Console.Write($fig)
    } catch {
      Write-Host '=== PsCraft ===' -ForegroundColor Cyan
    }
  }

  # ── Package feed bootstrap ──────────────────────────────────────────────────
  [void] PreparePackageFeeds() {
    $PackageProviders = Get-PackageProvider -ListAvailable -ea Ignore -Verbose:$false
    @('NuGet', 'PowerShellGet') | ForEach-Object {
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
  }

  # ── Dependency resolution ───────────────────────────────────────────────────
  [void] ResolveBuildRequirements() {
    $psd1 = [Path]::Combine($this.Path, "$([IO.DirectoryInfo]::new($this.Path).BaseName).psd1")
    if ([IO.File]::Exists($psd1)) {
      $data = [PsObject]([scriptblock]::Create("$([IO.File]::ReadAllText($psd1))").Invoke() | Select-Object *)
      $this.RequiredModules = ($data.RequiredModules + $this.RequiredModules) | Select-Object -Unique
    }
    $IsConnected = $( try {
        [Net.NetworkInformation.Ping]::new().Send('www.powershellgallery.com').Status -eq [Net.NetworkInformation.IPStatus]::Success
      } catch { $false } )
    $L = (($this.RequiredModules | Select-Object @{l = 'L'; e = { $_.Length } }).L | Sort-Object -Descending)[0]
    try {
      $status = [Status]::new([AnsiConsole]::Console.GetWriter())
      $status.RefreshRateMs = 80
      $mods = $this.RequiredModules
      $conn = $IsConnected
      $status.Start('[yellow]Resolving build dependencies...[/]', [Action[StatusContext]] {
          param($ctx)
          foreach ($name in $mods) {
            $ctx.Update("Checking $name ...")
            if ($conn) {
              Install-Module -Name $name -Verbose:$false -ea Stop
            } elseif (!((Get-Module -Name $name -ListAvailable -Verbose:$false))) {
              throw [System.Management.Automation.ItemNotFoundException]::new("Module $name is not installed.")
            }
          }
        })
    } catch {
      # Status not available — fall back
      foreach ($name in $this.RequiredModules) {
        try {
          if ($IsConnected) { Install-Module -Name $name -Verbose:$false -ea Stop }
          [BuildLog]::Write(" [+] Module $name$(' ' * ($L - $name.Length)) ready")
        } catch { $this.Cmdlet.ThrowTerminatingError($_) }
      }
    }
    $psds = (Get-Module -Name $this.RequiredModules -ListAvailable -Verbose:$false).Path | Sort-Object -Unique { Split-Path $_ -Leaf }
    $psds | Import-Module -Verbose:$false -ea Stop
  }

  # ── Dispatch ────────────────────────────────────────────────────────────────
  [int] Run([string[]]$tasks) {
    [Environment]::SetEnvironmentVariable('IsAC', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('IsCI', $(if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('TF_BUILD'))) { '1' } else { '0' }), [System.EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('RUN_ID', $(if ([bool][int]$env:IsAC -or $env:CI -eq 'true') { [Environment]::GetEnvironmentVariable('GITHUB_RUN_ID') } else { [Guid]::NewGuid().Guid.Substring(0, 21).Replace('-', [string]::Join('', (0..9 | Get-Random -Count 1))) + '_' }), [System.EnvironmentVariableTarget]::Process)
    Set-BuildVariables $this.Path $env:RUN_ID
    [BuildLog]::WriteHeading("Invoking tasks: [ $($tasks -join ', ') ]")
    $script:Psake_BuildFile = New-Item $([IO.Path]::GetTempFileName().Replace('.tmp', '.ps1'))
    $sbText = [BuildOrchestrator]::PSakeScriptBlock.ToString().Replace('<build_requirements>', [string]('@("' + ($this.RequiredModules -join '", "') + '")'))
    Set-Content -Path $script:Psake_BuildFile -Value $sbText | Out-Null
    try {
      $psakeParams = @{ nologo = $true; buildFile = $script:Psake_BuildFile.FullName; taskList = $tasks }
      Invoke-Psake @psakeParams
    } catch {
      $psake.error_message = $_
      $this.Cmdlet.ThrowTerminatingError($_)
    } finally {
      Remove-Item $script:Psake_BuildFile -Force -ea Ignore -Verbose:$false | Out-Null
    }
    return [int](!$psake.build_success)
  }

  # ── Post-build: local repo publish + env cleanup ────────────────────────────
  [void] Finalize([bool]$success) {
    [BuildLog]::WriteEnvironmentSummary("Build $($success ? 'complete' : 'Failed')")
    $LocalPSRepo = if (!(Get-Variable -Name IsWindows -ea Ignore) -or $(Get-Variable IsWindows -ValueOnly)) {
      [IO.Path]::Combine([Environment]::GetEnvironmentVariable('UserProfile'), 'LocalPSRepo')
    } else { [IO.Path]::Combine([Environment]::GetEnvironmentVariable('HOME'), 'LocalPSRepo') }

    if ($success) {
      [BuildLog]::WriteHeading('Create a Local repository')
      if (!(Test-Path -Path $LocalPSRepo -PathType Container -ea Ignore)) { New-Item -Path $LocalPSRepo -ItemType Directory | Out-Null }
      Register-PSRepository LocalPSRepo -SourceLocation $LocalPSRepo -PublishLocation $LocalPSRepo -InstallationPolicy Trusted -Verbose:$false -ea Ignore
      Register-PackageSource -Name LocalPsRepo -Location $LocalPSRepo -Trusted -ProviderName Bootstrap -ea Ignore
      if ($null -ne (Get-PSRepository LocalPSRepo -Verbose:$false -ea Ignore)) {
        $ModuleName = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
        $BuildNumber = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildNumber')
        $ModulePath = [IO.Path]::Combine($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildOutput')), $ModuleName, $BuildNumber)
        $ModulePackage = [IO.Path]::Combine($LocalPSRepo, "${ModuleName}.${BuildNumber}.nupkg")
        if ([IO.File]::Exists($ModulePackage)) { Remove-Item -Path $ModulePackage -Force -ea SilentlyContinue }
        [BuildLog]::WriteHeading('Publish to Local PsRepository')
        $RequiredMods = Read-ModuleData -File ([IO.Path]::Combine($ModulePath, "$ModuleName.psd1")) -Property RequiredModules -Verbose:$false
        foreach ($m in $RequiredMods) {
          $mdPath = (Get-Module $m -ListAvailable -Verbose:$false)[0].Path | Split-Path
          Publish-Module -Path $mdPath -Repository LocalPSRepo -Verbose:$false -ea Ignore
        }
        Publish-Module -Path $ModulePath -Repository LocalPSRepo -Verbose:$false
        Install-Module $ModuleName -Repository LocalPSRepo -Force -Verbose:$false
      } else {
        $this.Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new([Exception]::new('Failed to create LocalPsRepo'), 'LocalPsRepo_NOT_FOUND', 'ObjectNotFound', $LocalPSRepo))
      }
    }

    # Env cleanup
    if (![bool][int]$env:IsAC) {
      [BuildLog]::WriteHeading("CleanUp: Remove env variables")
      if (![string]::IsNullOrWhiteSpace($env:RUN_ID)) {
        $OldEnvNames = [Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like "$env:RUN_ID*" }
        foreach ($Name in $OldEnvNames) {
          [BuildLog]::Write("Remove env variable $Name")
          [Environment]::SetEnvironmentVariable($Name, $null)
        }
      }
      $ModuleName = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')
      $BuildNumber = [Environment]::GetEnvironmentVariable($env:RUN_ID + 'BuildNumber')
      if ($ModuleName) { Uninstall-Module $ModuleName -MinimumVersion $BuildNumber -Force -ea Ignore }
      if ([IO.Directory]::Exists($LocalPSRepo)) {
        Invoke-Command -ScriptBlock ([scriptblock]::Create("Unregister-PSRepository -Name 'LocalPSRepo' -Verbose:`$false -ea Ignore"))
        Remove-Item $LocalPSRepo -Verbose:$false -Force -Recurse -ea Ignore
      }
      [Environment]::SetEnvironmentVariable('RUN_ID', $null)
    }
  }

  # ── Help display ─────────────────────────────────────────────────────────────
  [void] ShowHelp([string]$buildFile) {
    [BuildLog]::WriteHeading('Getting help')
    try {
      $tasks = Get-PSakeScriptTasks -BuildFile $buildFile | Sort-Object -Property Name
      $table = [Table]::new()
      [void]$table.AddColumn([TableColumn]::new('Name'))
      [void]$table.AddColumn([TableColumn]::new('Description'))
      [void]$table.AddColumn([TableColumn]::new('DependsOn'))
      foreach ($t in $tasks) {
        [void]$table.AddRow(@($t.Name, "$($t.Description)", "$($t.DependsOn -join ', ')"))
      }
      [AnsiConsole]::Console.Write($table)
    } catch {
      Get-PSakeScriptTasks -BuildFile $buildFile | Sort-Object Name | Format-Table Name, Description, DependsOn -AutoSize
    }
  }
}
