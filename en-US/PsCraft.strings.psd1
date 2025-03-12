
@{
  ModuleName        = 'PsCraft'
  ModuleVersion     = [version]'0.3.0'
  ReleaseNotes      = "# Release Notes`n`n- Patches (Build script)`n- Optimizations`n"
  DefaultModuleData = @{
    Path                  = [Path]::Combine($Path, $Path.Split([Path]::DirectorySeparatorChar)[-1] + ".psd1")
    Guid                  = [guid]::NewGuid()
    Year                  = [datetime]::Now.Year
    Author                = [PsModuleData]::GetAuthorName()
    UserName              = [PsModuleData]::GetAuthorEmail().Split('@')[0]
    Copyright             = $("Copyright {0} {1} {2}. All rights reserved." -f [string][char]169, [datetime]::Now.Year, [PsModuleData]::GetAuthorName());
    RootModule            = $Name + '.psm1'
    ClrVersion            = [string]::Join('.', (Get-Variable 'PSVersionTable' -ValueOnly).SerializationVersion.ToString().split('.')[0..2])
    ModuleName            = $Name
    Description           = "A longer description of the Module, its purpose, common use cases, etc."
    CompanyName           = [PsModuleData]::GetAuthorEmail().Split('@')[0]
    AuthorEmail           = [PsModuleData]::GetAuthorEmail()
    ModuleVersion         = '0.1.0'
    RequiredModules       = @(
      "PsModuleBase"
    )
    PowerShellVersion     = [version][string]::Join('', (Get-Variable 'PSVersionTable').Value.PSVersion.Major.ToString(), '.0')
    Readme                = [PsModuleData]::GetModuleReadmeText()
    License               = [PsModuleData]::LICENSE_TXT ? [PsModuleData]::LICENSE_TXT : [PsModuleData]::GetModuleLicenseText()
    Builder               = {
      #!/usr/bin/env pwsh
      # .SYNOPSIS
      #   <ModuleName> buildScript v<ModuleVersion>
      # .DESCRIPTION
      #   A custom build script for the module <ModuleName>
      # .LINK
      #   https://github.com/<UserName>/<ModuleName>/blob/main/build.ps1
      # .EXAMPLE
      #   ./build.ps1 -Task Test
      #   This Will build the module, Import it and run tests using the ./Test-Module.ps1 script.
      #   ie: running ./build.ps1 only will "Compile & Import" the module; That's it, no tests.
      # .EXAMPLE
      #   ./build.ps1 -Task deploy
      #   Will build the module, test it and deploy it to PsGallery
      # .NOTES
      #   Author   : <Author>
      #   Copyright: <Copyright>
      #   License  : MIT
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

        [parameter(ParameterSetName = 'task')]
        [Alias('i')]
        [switch]$Import,

        [parameter(ParameterSetName = 'help')]
        [Alias('h', '-help')]
        [switch]$Help
      )

      begin {
        if ($PSCmdlet.ParameterSetName -eq 'help') { Get-Help $MyInvocation.MyCommand.Source -Full | Out-String | Write-Host -f Green; return }
        $IsGithubRun = ![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_WORKFLOW'))
        if ($($IsGithubRun ? $true : $(try { (Test-Connection "https://www.github.com" -Count 2 -TimeoutSeconds 1 -ea Ignore -Verbose:$false | Select-Object -expand Status) -contains "Success" } catch { Write-Warning "Test Connection Failed. $($_.Exception.Message)"; $false }))) {
          $req = Invoke-WebRequest -Method Get -Uri https://raw.githubusercontent.com/chadnpc/PsCraft/refs/heads/main/Public/Build-Module.ps1 -SkipHttpErrorCheck -Verbose:$false
          if ($req.StatusCode -ne 200) { throw "Failed to download Build-Module.ps1" }
          $t = New-Item $([IO.Path]::GetTempFileName().Replace('.tmp', '.ps1')) -Verbose:$false; Set-Content -Path $t.FullName -Value $req.Content; . $t.FullName; Remove-Item $t.FullName -Verbose:$false
        } else {
          $m = Get-InstalledModule PsCraft -Verbose:$false -ea Ignore
          $b = [IO.FileInfo][IO.Path]::Combine($m.InstalledLocation, 'Public', 'Build-Module.ps1')
          if ($b.Exists) { . $b.FullName }
        }
      }
      process {
        Build-Module -Task $Task -Path $Path -Import:$Import
      }
    }
    Tester                = {
      #!/usr/bin/env pwsh
      # .SYNOPSIS
      #   <ModuleName> testScript v<ModuleVersion>
      # .EXAMPLE
      #   ./Test-Module.ps1 -version <ModuleVersion>
      #   Will test the module in ./BuildOutput/<ModuleName>/<ModuleVersion>/
      # .EXAMPLE
      #   ./Test-Module.ps1
      #   Will test the latest  module version in ./BuildOutput/<ModuleName>/
      param (
        [Parameter(Mandatory = $false, Position = 0)]
        [Alias('Module')][string]$ModulePath = $PSScriptRoot,
        # Path Containing Tests
        [Parameter(Mandatory = $false, Position = 1)]
        [Alias('Tests')][string]$TestsPath = [IO.Path]::Combine($PSScriptRoot, 'Tests'),

        # Version string
        [Parameter(Mandatory = $false, Position = 2)]
        [ValidateScript({
            if (($_ -as 'version') -is [version]) {
              return $true
            } else {
              throw [System.IO.InvalidDataException]::New('Please Provide a valid version')
            }
          }
        )][ArgumentCompleter({
            [OutputType([System.Management.Automation.CompletionResult])]
            param([string]$CommandName, [string]$ParameterName, [string]$WordToComplete, [System.Management.Automation.Language.CommandAst]$CommandAst, [System.Collections.IDictionary]$FakeBoundParameters)
            $CompletionResults = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
            $b_Path = [IO.Path]::Combine($PSScriptRoot, 'BuildOutput', '<ModuleName>')
            if ((Test-Path -Path $b_Path -PathType Container -ErrorAction Ignore)) {
              [IO.DirectoryInfo]::New($b_Path).GetDirectories().Name | Where-Object { $_ -like "*$wordToComplete*" -and $_ -as 'version' -is 'version' } | ForEach-Object { [void]$CompletionResults.Add([System.Management.Automation.CompletionResult]::new($_, $_, "ParameterValue", $_)) }
            }
            return $CompletionResults
          }
        )]
        [string]$version,
        [switch]$skipBuildOutputTest,
        [switch]$CleanUp
      )
      begin {
        $TestResults = $null
        $BuildOutput = [IO.DirectoryInfo]::New([IO.Path]::Combine($PSScriptRoot, 'BuildOutput', '<ModuleName>'))
        if (!$BuildOutput.Exists) {
          Write-Warning "NO_Build_OutPut | Please make sure to Build the module successfully before running tests..";
          throw [System.IO.DirectoryNotFoundException]::new("Cannot find path '$($BuildOutput.FullName)' because it does not exist.")
        }
        # Get latest built version
        if ([string]::IsNullOrWhiteSpace($version)) {
          $version = $BuildOutput.GetDirectories().Name -as 'version[]' | Select-Object -Last 1
        }
        $BuildOutDir = Resolve-Path $([IO.Path]::Combine($PSScriptRoot, 'BuildOutput', '<ModuleName>', $version)) -ErrorAction Ignore | Get-Item -ErrorAction Ignore
        if (!$BuildOutDir.Exists) { throw [System.IO.DirectoryNotFoundException]::new($BuildOutDir) }
        $manifestFile = [IO.FileInfo]::New([IO.Path]::Combine($BuildOutDir.FullName, "<ModuleName>.psd1"))
        Write-Host "[+] Checking Prerequisites ..." -ForegroundColor Green
        if (!$BuildOutDir.Exists) {
          $msg = 'Directory "{0}" Not Found. First make sure you successfuly built the module.' -f ([IO.Path]::GetRelativePath($PSScriptRoot, $BuildOutDir.FullName))
          if ($skipBuildOutputTest.IsPresent) {
            Write-Warning "$msg"
          } else {
            throw [System.IO.DirectoryNotFoundException]::New($msg)
          }
        }
        if (!$skipBuildOutputTest.IsPresent -and !$manifestFile.Exists) {
          throw [System.IO.FileNotFoundException]::New("Could Not Find Module manifest File $([IO.Path]::GetRelativePath($PSScriptRoot, $manifestFile.FullName))")
        }
        if (!(Test-Path -Path $([IO.Path]::Combine($PSScriptRoot, "<ModuleName>.psd1")) -PathType Leaf -ErrorAction Ignore)) { throw [System.IO.FileNotFoundException]::New("Module manifest file Was not Found in '$($BuildOutDir.FullName)'.") }
        $script:fnNames = [System.Collections.Generic.List[string]]::New(); $testFiles = [System.Collections.Generic.List[IO.FileInfo]]::New()
        [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', '<ModuleName>.Integration.Tests.ps1')))
        [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', '<ModuleName>.Features.Tests.ps1')))
        [void]$testFiles.Add([IO.FileInfo]::New([IO.Path]::Combine("$PSScriptRoot", 'Tests', '<ModuleName>.Module.Tests.ps1')))
      }

      process {
        Get-Module PsCraft | Remove-Module -Force -Verbose:$false
        Write-Host "[+] Checking test files ..." -ForegroundColor Green
        $missingTestFiles = $testFiles.Where({ !$_.Exists })
        if ($missingTestFiles.count -gt 0) { throw [System.IO.FileNotFoundException]::new($($testFiles.BaseName -join ', ')) }
        Write-Host "[+] Testing ModuleManifest ..." -ForegroundColor Green
        if (!$skipBuildOutputTest.IsPresent) {
          Test-ModuleManifest -Path $manifestFile.FullName -ErrorAction Stop -Verbose
        }
        $PesterConfig = New-PesterConfiguration
        $PesterConfig.TestResult.OutputFormat = "NUnitXml"
        $PesterConfig.TestResult.OutputPath = [IO.Path]::Combine("$TestsPath", "results.xml")
        $PesterConfig.TestResult.Enabled = $True
        $TestResults = Invoke-Pester -Configuration $PesterConfig
      }

      end {
        return $TestResults
      }
    }
    LocalData             = {
      @{
        ModuleName    = '<ModuleName>'
        ModuleVersion = '0.1.0'
        ReleaseNotes  = '<ReleaseNotes>'
      }
    }
    LicenseUri            = "https://$([PsModuleData]::GetAuthorName()).MIT-license.org"
    ProjectUri            = "https://github.com/chadnpc/$Name"
    IconUri               = 'https://github.com/user-attachments/assets/1220c30e-a309-43c3-9a80-1948dae30e09'
    rootLoader            = {
      #!/usr/bin/env pwsh
      <#
        using namespace System.IO
        using namespace System.Collections.Generic
        using namespace System.Management.Automation

        #Requires -RunAsAdministrator
        #Requires -Modules PsModuleBase
        #Requires -Psedition Core

        #region    Classes
        class <ModuleName> : PsModuleBase {
        # Define the class. Try constructors, properties, or methods.
        }
        #>
      #endregion Classes
      # Types that will be available to users when they import the module.
      $typestoExport = @(
        #[<ModuleName>]
      )
      $TypeAcceleratorsClass = [PsObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
      foreach ($Type in $typestoExport) {
        if ($Type.FullName -in $TypeAcceleratorsClass::Get.Keys) {
          $Message = @(
            "Unable to register type accelerator '$($Type.FullName)'"
            'Accelerator already exists.'
          ) -join ' - '
          "TypeAcceleratorAlreadyExists $Message" | Write-Debug
        }
      }
      # Add type accelerators for every exportable type.
      foreach ($Type in $typestoExport) {
        $TypeAcceleratorsClass::Add($Type.FullName, $Type)
      }
      # Remove type accelerators when the module is removed.
      $MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
        foreach ($Type in $typestoExport) {
          $TypeAcceleratorsClass::Remove($Type.FullName)
        }
      }.GetNewClosure();

      $scripts = @();
      $Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
      $scripts += Get-ChildItem "$PSScriptRoot/Private" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
      $scripts += $Public

      foreach ($file in $scripts) {
        Try {
          if ([string]::IsNullOrWhiteSpace($file.fullname)) { continue }
          . "$($file.fullname)"
        } Catch {
          Write-Warning "Failed to import function $($file.BaseName): $_"
          $host.UI.WriteErrorLine($_)
        }
      }

      $Param = @{
        Function = $Public.BaseName
        Cmdlet   = '*'
        Alias    = '*'
        Verbose  = $false
      }
      Export-ModuleMember @Param
    }
    ModuleTest            = {
      $script:ModuleName = (Get-Item "$PSScriptRoot/..").Name
      $script:ModulePath = Resolve-Path "$PSScriptRoot/../BuildOutput/$ModuleName" | Get-Item
      $script:moduleVersion = ((Get-ChildItem $ModulePath).Where({ $_.Name -as 'version' -is 'version' }).Name -as 'version[]' | Sort-Object -Descending)[0].ToString()

      Write-Host "[+] Testing the latest built module:" -ForegroundColor Green
      Write-Host "      ModuleName    $ModuleName"
      Write-Host "      ModulePath    $ModulePath"
      Write-Host "      Version       $moduleVersion`n"

      Get-Module -Name $ModuleName | Remove-Module # Make sure no versions of the module are loaded

      Write-Host "[+] Reading module information ..." -ForegroundColor Green
      $script:ModuleInformation = Import-Module -Name "$ModulePath" -PassThru
      $script:ModuleInformation | Format-List

      Write-Host "[+] Get all functions present in the Manifest ..." -ForegroundColor Green
      $script:ExportedFunctions = $ModuleInformation.ExportedFunctions.Values.Name
      Write-Host "      ExportedFunctions: " -ForegroundColor DarkGray -NoNewline
      Write-Host $($ExportedFunctions -join ', ')
      $script:PS1Functions = Get-ChildItem -Path "$ModulePath/$moduleVersion/Public/*.ps1" -Recurse

      Describe "Module tests for $($([Environment]::GetEnvironmentVariable($env:RUN_ID + 'ProjectName')))" {
        Context " Confirm valid Manifest file" {
          It "Should contain RootModule" {
            ![string]::IsNullOrWhiteSpace($ModuleInformation.RootModule) | Should -Be $true
          }

          It "Should contain ModuleVersion" {
            ![string]::IsNullOrWhiteSpace($ModuleInformation.Version) | Should -Be $true
          }

          It "Should contain GUID" {
            ![string]::IsNullOrWhiteSpace($ModuleInformation.Guid) | Should -Be $true
          }

          It "Should contain Author" {
            ![string]::IsNullOrWhiteSpace($ModuleInformation.Author) | Should -Be $true
          }

          It "Should contain Description" {
            ![string]::IsNullOrWhiteSpace($ModuleInformation.Description) | Should -Be $true
          }
        }
        Context " Should export all public functions " {
          It "Compare the number of Function Exported and the PS1 files found in the public folder" {
            $status = $ExportedFunctions.Count -eq $PS1Functions.Count
            $status | Should -Be $true
          }

          It "The number of missing functions should be 0 " {
            If ($ExportedFunctions.count -ne $PS1Functions.count) {
              $Compare = Compare-Object -ReferenceObject $ExportedFunctions -DifferenceObject $PS1Functions.Basename
              $($Compare.InputObject -Join '').Trim() | Should -BeNullOrEmpty
            }
          }
        }
        Context " Confirm files are valid Powershell syntax " {
          $_scripts = $(Get-Item -Path "$ModulePath/$moduleVersion").GetFiles(
            "*", [System.IO.SearchOption]::AllDirectories
          ).Where({ $_.Extension -in ('.ps1', '.psd1', '.psm1') })
          $testCase = $_scripts | ForEach-Object { @{ file = $_ } }
          It "ie: each Script/Ps1file should have valid Powershell sysntax" -TestCases $testCase {
            param($file) $contents = Get-Content -Path $file.fullname -ErrorAction Stop
            $errors = $null; [void][System.Management.Automation.PSParser]::Tokenize($contents, [ref]$errors)
            $errors.Count | Should -Be 0
          }
        }
        Context " Confirm there are no duplicate function names in private and public folders" {
          It ' Should have no duplicate functions' {
            $Publc_Dir = Get-Item -Path ([IO.Path]::Combine("$ModulePath/$moduleVersion", 'Public'))
            $Privt_Dir = Get-Item -Path ([IO.Path]::Combine("$ModulePath/$moduleVersion", 'Private'))
            $funcNames = @(); Test-Path -Path ([string[]]($Publc_Dir, $Privt_Dir)) -PathType Container -ErrorAction Stop
            $Publc_Dir.GetFiles("*", [System.IO.SearchOption]::AllDirectories) + $Privt_Dir.GetFiles("*", [System.IO.SearchOption]::AllDirectories) | Where-Object { $_.Extension -eq '.ps1' } | ForEach-Object { $funcNames += $_.BaseName }
            $($funcNames | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -BeLessThan 1
          }
        }
      }
      Remove-Module -Name $ModuleName -Force
    }
    FeatureTest           = {
      Describe "Feature tests: <ModuleName>" {
        Context "Feature 1" {
          It "Does something expected" {
            # Write tests to verify the behavior of a specific feature.
            # For instance, if you have a feature to change the console background color,
            # you could simulate the invocation of the related function and check if the color changes as expected.
          }
        }
        Context "Feature 2" {
          It "Performs another expected action" {
            # Write tests for another feature.
          }
        }
        # TODO: Add more contexts and tests to cover various features and functionalities.
      }
    }
    IntegrationTest       = {
      # verify the interactions and behavior of the module's components when they are integrated together.
      Describe "Integration tests: <ModuleName>" {
        Context "Functionality Integration" {
          It "Performs expected action" {
            # Here you can write tests to simulate the usage of your functions and validate their behavior.
            # For instance, if your module provides cmdlets to customize the command-line environment,
            # you could simulate the invocation of those cmdlets and check if the environment is modified as expected.
          }
        }
        # TODO: Add more contexts and tests as needed to cover various integration scenarios.
      }
    }
    ScriptAnalyzer        = {
      @{
        IncludeDefaultRules = $true
        ExcludeRules        = @(
          'PSAvoidUsingWriteHost',
          'PSReviewUnusedParameter',
          'PSUseSingularNouns'
        )

        Rules               = @{
          PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
          }

          PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $true
          }

          PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            IndentationSize     = 2
          }

          PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $false
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
          }

          PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
          }

          PSUseCorrectCasing         = @{
            Enable = $true
          }
        }
      }
    }
    DelWorkflowsyaml      = [PsModuleData]::GetModuleDelWorkflowsyaml()
    Codereviewyaml        = [PsModuleData]::GetModuleCodereviewyaml()
    Publishyaml           = [PsModuleData]::GetModulePublishyaml()
    GitIgnore             = ".env`n.env.local`nBuildOutput/`nLocalPSRepo/`nTests/results.xml`nTests/Resources/"
    CICDyaml              = [PsModuleData]::GetModuleCICDyaml()
    DotEnv                = "#usage example: Publish-Module -Path BuildOutput/cliHelper.xconvert/0.1.3 -NuGetApiKey `$env:NUGET_API_KEY`nNUGET_API_KEY=somethinglike_6arai6wi2rgzepnx6shcc24x2ka"
    Tags                  = [string[]]("PowerShell", $Name, [Environment]::UserName)
    ReleaseNotes          = "# Release Notes`n`n- Version_<ModuleVersion>`n- Functions ...`n- Optimizations`n"
    ProcessorArchitecture = 'None'
    #CompatiblePSEditions = $($Ps_Ed = (Get-Variable 'PSVersionTable').Value.PSEdition; if ([string]::IsNullOrWhiteSpace($Ps_Ed)) { 'Desktop' } else { $Ps_Ed }) # skiped on purpose. <<< https://blog.netnerds.net/2023/03/dont-waste-your-time-with-core-versions
  }
}
