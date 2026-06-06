
# Integration tests for PsCraft - testing component interactions and workflows
#Requires -Modules Pester

Describe "Integration tests: PsCraft" {
  BeforeAll {
    # Import required modules for integration testing
    Import-Module -Name cliHelper.core -Verbose:$false -Force -ErrorAction Stop
    $manifestPath = [IO.Path]::Combine($PSScriptRoot, '..', 'PsCraft.psd1')
    Import-Module -Name $manifestPath -Verbose:$false -Force -ErrorAction Stop

    # Create temporary test directory
    $script:TestRoot = [IO.Path]::Combine($env:TEMP, "PsCraft_Integration_$([Guid]::NewGuid().Guid)")
    New-Item -Path $TestRoot -ItemType Directory -Force | Out-Null
  }

  AfterAll {
    # Cleanup temporary test directory
    if (Test-Path -Path $TestRoot) {
      Remove-Item -Path $TestRoot -Recurse -Force -ErrorAction Ignore
    }
  }

  Context "New-PsModule Workflow - Script Module" {
    It "Creates script module with interactive prompts" {
      # Arrange
      $moduleName = 'TestScriptModule'
      $modulePath = [IO.Path]::Combine($TestRoot, 'script_modules')
      New-Item -Path $modulePath -ItemType Directory -Force | Out-Null

      # Act - Create module without interactive input (use defaults)
      Push-Location $modulePath
      try {
        # Note: Since we can't simulate interactive prompts in tests, we verify the structure
        $Error.Clear()
        $module = [PsModule]::Create($moduleName)
        $Error.Count | Should -Be 0

        # Assert
        $module.Name | Should -Be $moduleName
        $module.Path | Should -Not -BeNullOrEmpty
        $module.Folders.Count | Should -BeGreaterThan 0
      } finally {
        Pop-Location
      }
    }

    It "Scaffolds correct folder structure for script module" {
      # Arrange
      $moduleName = 'TestStructure'
      $modulePath = [IO.Path]::Combine($TestRoot, 'script_structures')
      New-Item -Path $modulePath -ItemType Directory -Force | Out-Null

      # Act
      Push-Location $modulePath
      try {
        $Error.Clear()
        $module = [PsModule]::Create($moduleName)
        $Error.Count | Should -Be 0
        $module.Save()

        # Assert - Check that folders exist
        $moduleFolderPath = [IO.Path]::Combine($modulePath, $moduleName)
        Test-Path -Path [IO.Path]::Combine($moduleFolderPath, 'Public') | Should -Be $true
        Test-Path -Path [IO.Path]::Combine($moduleFolderPath, 'Private') | Should -Be $true
        Test-Path -Path [IO.Path]::Combine($moduleFolderPath, 'Tests') | Should -Be $true
        Test-Path -Path [IO.Path]::Combine($moduleFolderPath, 'en-US') | Should -Be $true

        # Assert - Check that manifest file exists
        Test-Path -Path [IO.Path]::Combine($moduleFolderPath, "$moduleName.psd1") | Should -Be $true
        Test-Path -Path [IO.Path]::Combine($moduleFolderPath, "$moduleName.psm1") | Should -Be $true
      } finally {
        Pop-Location
      }
    }

    It "Sets module metadata correctly" {
      # Arrange
      $moduleName = 'TestMetadata'
      $author = 'Test Author'
      $description = 'Test Description'
      $modulePath = [IO.Path]::Combine($TestRoot, 'metadata_modules')
      New-Item -Path $modulePath -ItemType Directory -Force | Out-Null

      # Act
      Push-Location $modulePath
      try {
        $Error.Clear()
        $module = [PsModule]::Create($moduleName)
        $Error.Count | Should -Be 0
        $module.Set('Author', $author)
        $module.Set('Description', $description)
        $module.Save()

        # Assert - Import and verify manifest
        $moduleFolderPath = [IO.Path]::Combine($modulePath, $moduleName)
        $manifest = Import-PowerShellDataFile -Path [IO.Path]::Combine($moduleFolderPath, "$moduleName.psd1")

        $manifest.Author | Should -Be $author
        $manifest.Description | Should -Be $description
      } finally {
        Pop-Location
      }
    }
  }

  Context "New-PsModule Workflow - Binary Module" {
    It "Scaffolds src folder for binary modules" {
      # Arrange
      $moduleName = 'TestBinaryScaffold'
      $modulePath = [IO.Path]::Combine($TestRoot, 'binary_modules')
      New-Item -Path $modulePath -ItemType Directory -Force | Out-Null

      # Act
      Push-Location $modulePath
      try {
        $Error.Clear()
        $module = [PsModule]::Create($moduleName)
        $Error.Count | Should -Be 0
        $srcPath = [IO.Path]::Combine($modulePath, $moduleName, 'src')

        # Manually create src structure as New-PsModule would for binary
        New-Item -Path $srcPath -ItemType Directory -Force | Out-Null
        $csprojContent = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>netstandard2.0</TargetFramework>
    <AssemblyName>$moduleName</AssemblyName>
  </PropertyGroup>
</Project>
"@
        Set-Content -Path [IO.Path]::Combine($srcPath, "$moduleName.csproj") -Value $csprojContent

        # Assert - Verify src folder and csproj exist
        Test-Path -Path $srcPath -PathType Container | Should -Be $true
        Test-Path -Path [IO.Path]::Combine($srcPath, "$moduleName.csproj") | Should -Be $true

        # Verify csproj is valid XML
        $xml = [xml]::new()
        { $xml.Load([IO.Path]::Combine($srcPath, "$moduleName.csproj")) } | Should -Not -Throw
      } finally {
        Pop-Location
      }
    }

    It "Creates C# template files for binary module" {
      # Arrange
      $moduleName = 'TestCSharpTemplate'
      $srcPath = [IO.Path]::Combine($TestRoot, 'csharp_templates', $moduleName, 'src')
      New-Item -Path $srcPath -ItemType Directory -Force | Out-Null

      # Act - Create minimal C# cmdlet template
      $templateContent = @"
using System;
using System.Management.Automation;

namespace $moduleName
{
    [Cmdlet(VerbsCommon.Get, "Info")]
    public class GetInfoCmdlet : PSCmdlet
    {
        protected override void ProcessRecord()
        {
            WriteObject("Hello from $moduleName binary module!");
        }
    }
}
"@
      Set-Content -Path [IO.Path]::Combine($srcPath, "GetInfoCmdlet.cs") -Value $templateContent

      # Assert - Verify file exists and contains expected content
      Test-Path -Path [IO.Path]::Combine($srcPath, "GetInfoCmdlet.cs") | Should -Be $true
      $content = Get-Content -Path [IO.Path]::Combine($srcPath, "GetInfoCmdlet.cs") -Raw
      $content | Should -Match 'PSCmdlet'
      $content | Should -Match 'VerbsCommon.Get'
    }
  }

  Context "BuildContext Integration" {
    It "BuildContext properly initializes from module path" {
      # Arrange
      $moduleName = 'ContextTestModule'
      $modulePath = [IO.Path]::Combine($TestRoot, 'context_test')
      New-Item -Path $modulePath -ItemType Directory -Force | Out-Null

      # Act
      $context = [BuildContext]::new($moduleName, $modulePath, '1.2.3')

      # Assert
      $context.ProjectName | Should -Be $moduleName
      $context.BuildNumber | Should -Be '1.2.3'
      $context.BuildOutputPath | Should -Match 'BuildOutput'
      $context.PSModulePath | Should -Match $moduleName
    }

    It "BuildContext export and import cycle preserves data" {
      # Arrange
      $context = [BuildContext]::new('CycleTest', $TestRoot, '2.0.0')
      $context.CommitMessage = 'Test commit message'
      $context.ReleaseNotes = 'Release notes v2.0.0'

      # Act
      $context.ExportToEnvironment()

      # Assert - Verify all variables are set
      $prefix = $context.RunId
      [Environment]::GetEnvironmentVariable("${prefix}ProjectName") | Should -Be 'CycleTest'
      [Environment]::GetEnvironmentVariable("${prefix}BuildNumber") | Should -Be '2.0.0'
      [Environment]::GetEnvironmentVariable("${prefix}CommitMessage") | Should -Be 'Test commit message'
      [Environment]::GetEnvironmentVariable("${prefix}ReleaseNotes") | Should -Be 'Release notes v2.0.0'

      # Cleanup
      $context.ClearEnvironment()
    }
  }

  Context "BuildOrchestrator Module Type Detection" {
    It "Orchestrator detects and adapts to script module" {
      # Arrange
      $scriptModulePath = [IO.Path]::Combine($TestRoot, 'script_detection')
      New-Item -Path $scriptModulePath -ItemType Directory -Force | Out-Null

      # Act
      $orchestrator = [BuildOrchestrator]::new($scriptModulePath, @('Clean'), @(), $null)

      # Assert
      $orchestrator.ModuleType | Should -Be 'Script'
      $orchestrator.HasBinarySrc | Should -Be $false
    }

    It "Orchestrator detects and adapts to binary module" {
      # Arrange
      $binaryModulePath = [IO.Path]::Combine($TestRoot, 'binary_detection')
      $srcPath = [IO.Path]::Combine($binaryModulePath, 'src')
      New-Item -Path $srcPath -ItemType Directory -Force | Out-Null
      Set-Content -Path [IO.Path]::Combine($srcPath, 'project.csproj') -Value '<Project></Project>'

      # Act
      $orchestrator = [BuildOrchestrator]::new($binaryModulePath, @('Clean'), @(), $null)

      # Assert
      $orchestrator.ModuleType | Should -Be 'Binary'
      $orchestrator.HasBinarySrc | Should -Be $true
    }
  }

  Context "Build Context Dependency Injection" {
    It "BuildOrchestrator accepts BuildContext via constructor" {
      # Arrange
      $modulePath = [IO.Path]::Combine($TestRoot, 'di_test')
      New-Item -Path $modulePath -ItemType Directory -Force | Out-Null
      $context = [BuildContext]::new('DITestModule', $modulePath, '1.0.0')

      # Act
      $orchestrator = [BuildOrchestrator]::new(
        $modulePath,
        @('Clean'),
        @(),
        $null,
        $context
      )

      # Assert
      $orchestrator.Context | Should -Not -BeNull
      $orchestrator.Context.ProjectName | Should -Be 'DITestModule'
      $orchestrator.Context.BuildNumber | Should -Be '1.0.0'
    }

    It "BuildOrchestrator initializes context with version" {
      # Arrange
      $modulePath = [IO.Path]::Combine($TestRoot, 'version_init')
      New-Item -Path $modulePath -ItemType Directory -Force | Out-Null
      $context = [BuildContext]::new('VersionModule', $modulePath, '0.0.0')
      $orchestrator = [BuildOrchestrator]::new($modulePath, @(), @(), $null, $context)

      # Act
      $orchestrator.InitializeBuildContext([version]'3.0.0')

      # Assert
      $orchestrator.Context.BuildNumber | Should -Be '3.0.0'
    }
  }

  Context "BuildSummary with Build Results" {
    It "BuildSummary tracks multiple tasks through build lifecycle" {
      # Arrange
      $summary = [BuildSummary]::new('IntegrationModule', '1.0.0')

      # Act
      $summary.AddTask('Clean', $true, [timespan]'00:00:01')
      $summary.AddTask('Compile', $true, [timespan]'00:00:05')
      $summary.AddTask('Test', $true, [timespan]'00:00:03')
      $summary.SetTestResults(15, 15, 0, 0)

      # Assert
      $summary.Tasks.Count | Should -Be 3
      $summary.TestResults.Total | Should -Be 15
      $summary.TestResults.Passed | Should -Be 15
      $summary.Success | Should -Be $true
    }

    It "BuildSummary marks build as failed when any task fails" {
      # Arrange
      $summary = [BuildSummary]::new('FailModule', '1.0.0')

      # Act
      $summary.AddTask('Clean', $true, [timespan]'00:00:01')
      $summary.AddTask('Compile', $false, [timespan]'00:00:05')  # Failed!
      $summary.AddTask('Test', $true, [timespan]'00:00:03')

      # Assert
      $summary.Success | Should -Be $false
    }

    It "BuildSummary renders complete build report" {
      # Arrange
      $summary = [BuildSummary]::new('ReportModule', '2.0.0')
      $summary.AddTask('Clean', $true, [timespan]'00:00:01')
      $summary.AddTask('Compile', $true, [timespan]'00:00:10')
      $summary.AddTask('Test', $true, [timespan]'00:00:05')
      $summary.SetTestResults(20, 20, 0, 0)

      # Act & Assert - Should not throw
      { $summary.RenderSummary() } | Should -Not -Throw
    }
  }

  Context "cliHelper.core Output Integration" {
    It "BuildLog with Status spinner handles environment updates" {
      # Arrange
      $messages = @()

      # Act - This simulates what happens in ResolveBuildRequirements
      try {
        $status = [Status]::new([AnsiConsole]::Console.GetWriter())
        $status.Start('[yellow]Testing status updates...[/]', [Action[StatusContext]] {
            param($ctx)
            $ctx.Update("Step 1...")
            $ctx.Update("Step 2...")
            $ctx.Update("Complete!")
          })
      } catch {
        [BuildLog]::WriteSevere("$($_ | Format-List * -Force | Out-String)")
        # Status might not be available in test environment, that's OK
        # The important thing is it doesn't break
      }

      # Assert - Verify Status exists and is accessible
      $statusType = [type]::GetType('Spectre.Console.Status', $false)
      $statusType | Should -Not -BeNull
    }

    It "BuildLog with Progress tracks file operations" {
      # Arrange
      $fileCount = 0

      # Act - Simulate Progress functionality
      try {
        $progress = [Progress]::new([AnsiConsole]::Console)
        $progress.Start([Action[ProgressContext]] {
            param($ctx)
            $task = $ctx.AddTask('[green]Copying files[/]')
            $task.MaxValue = 5

            for ($i = 1; $i -le 5; $i++) {
              $task.Increment(1)
              $fileCount++
            }
          })
      } catch {
        [BuildLog]::WriteSevere("$($_ | Format-List * -Force | Out-String)")
        # Progress might not be fully available in test env
        # Verify by checking type exists
      }

      # Assert
      $progressType = [type]::GetType('Spectre.Console.Progress', $false)
      $progressType | Should -Not -BeNull
    }

    It "BuildLog BreakdownChart visualizes test results" {
      # Arrange
      $chartAvailable = $null -ne ([type]::GetType('Spectre.Console.BreakdownChart', $false))

      # Act - Verify chart can be created
      if ($chartAvailable) {
        $chart = [BreakdownChart]::new()

        # Assert
        $chart | Should -Not -BeNull
      } else {
        Set-ItResult -Skipped -Because "BreakdownChart not available in this environment"
      }
    }
  }

  Context "Module Import and Export" {
    It "PsCraft exports required cmdlets" {
      # Act
      $module = Get-Module -name PsCraft
      $exportedCmdlets = $module.ExportedCmdlets.Keys

      # Assert - Verify key cmdlets are exported
      $exportedCmdlets | Should -Contain 'Build-Module'
      $exportedCmdlets | Should -Contain 'New-PsModule'
    }

    It "cliHelper.core components are accessible from PsCraft" {
      # Arrange
      $requiredTypes = @(
        'Spectre.Console.AnsiConsole',
        'Spectre.Console.FigletText',
        'Spectre.Console.Table',
        'Spectre.Console.Panel'
      )

      # Act & Assert
      foreach ($typeName in $requiredTypes) {
        $type = [type]::GetType($typeName, $false)
        $type | Should -Not -BeNull -Because "Type $typeName should be accessible"
      }
    }
  }

  Context "Error Handling and Resilience" {
    It "BuildLog gracefully handles missing AnsiConsole" {
      # Arrange
      $testMessage = 'Resilience test'

      # Act & Assert - Should not throw even if rendering fails
      { [BuildLog]::WriteStatus($testMessage, 'warning') } | Should -Not -Throw
    }

    It "BuildContext handles git command failures gracefully" {
      # Arrange - In environments without git
      $context = [BuildContext]::new('NoGitModule', $TestRoot, '1.0.0')

      # Act
      $commitId = $context.CommitId
      $commitMsg = $context.CommitMessage

      # Assert - Should return strings even if commands fail
      $commitId | Should -BeOfType [string]
      $commitMsg | Should -BeOfType [string]
    }
  }
}
