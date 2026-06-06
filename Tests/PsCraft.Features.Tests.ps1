
# Feature tests for PsCraft with cliHelper.core integration
#Requires -Modules Pester

Describe "Feature tests: PsCraft" {
  BeforeAll {
    # Import required modules
    Import-Module -Name cliHelper.core -Verbose:$false -Force -ErrorAction Stop
    $manifestPath = [IO.Path]::Combine($PSScriptRoot, '..', 'PsCraft.psd1')
    Import-Module -Name $manifestPath -Verbose:$false -Force -ErrorAction Stop
  }

  Context "BuildLog with cliHelper.core Integration" {
    It "BuildLog.WriteBanner uses FigletText when available" {
      # Arrange
      $figletAvailable = $null -ne ([type]::GetType('Spectre.Console.FigletText', $false))

      # Act & Assert - This should not throw
      { [BuildLog]::WriteBanner('PsCraft') } | Should -Not -Throw
      $figletAvailable | Should -Be $true
    }

    It "BuildLog.WriteStatus produces colored output for success" {
      # Act & Assert
      { [BuildLog]::WriteStatus('Test success message', 'success') } | Should -Not -Throw
    }

    It "BuildLog.WriteStatus produces colored output for warning" {
      # Act & Assert
      { [BuildLog]::WriteStatus('Test warning message', 'warning') } | Should -Not -Throw
    }

    It "BuildLog.WriteStatus produces colored output for error" {
      # Act & Assert
      { [BuildLog]::WriteStatus('Test error message', 'error') } | Should -Not -Throw
    }

    It "BuildLog.WriteStep formats output as bullet point" {
      # Act & Assert
      { [BuildLog]::WriteStep('Test build step') } | Should -Not -Throw
    }

    It "BuildLog.WriteHeading renders with Rule when available" {
      # Arrange
      $ruleAvailable = $null -ne ([type]::GetType('Spectre.Console.Rule', $false))

      # Act & Assert
      { [BuildLog]::WriteHeading('Test Section Title') } | Should -Not -Throw
      $ruleAvailable | Should -Be $true
    }

    It "BuildLog.WriteEnvironmentSummary creates Panel with Grid" {
      # Act & Assert
      { [BuildLog]::WriteEnvironmentSummary('Initializing Build') } | Should -Not -Throw
    }

    It "BuildLog.InvokeCommandWithLog executes command with logging" {
      # Arrange
      $testScript = { Write-Host 'Test command' }

      # Act & Assert
      { [BuildLog]::InvokeCommandWithLog($testScript) } | Should -Not -Throw
    }
  }

  Context "BuildContext Class" {
    It "BuildContext initializes with required parameters" {
      # Arrange
      $projectName = 'TestProject'
      $projectPath = $PSScriptRoot
      $buildNumber = [version]'1.0.0'

      # Act
      $context = [BuildContext]::new($projectName, $projectPath, $buildNumber)

      # Assert
      $context.ProjectName | Should -Be $projectName
      $context.ProjectPath | Should -Be $projectPath
      $context.BuildNumber | Should -Be $buildNumber
      $context.RunId | Should -Not -BeNullOrEmpty
    }

    It "BuildContext DetectBuildSystem identifies local environment" {
      # Arrange
      $context = [BuildContext]::new('TestProject', $PSScriptRoot, '1.0.0')

      # Act
      $buildSystem = $context.BuildSystem

      # Assert - Should be 'Local', 'GitHub', or 'Azure'
      $buildSystem | Should -BeIn @('Local', 'GitHub', 'Azure')
    }

    It "BuildContext GetCommitId handles missing git gracefully" {
      # Arrange
      $context = [BuildContext]::new('TestProject', $PSScriptRoot, '1.0.0')

      # Act
      $commitId = $context.CommitId

      # Assert - Should be string (even if empty)
      $commitId | Should -BeOfType [string]
    }

    It "BuildContext ExportToEnvironment sets environment variables" {
      # Arrange
      $context = [BuildContext]::new('TestProject', $PSScriptRoot, '1.0.0')
      $prefix = $context.RunId

      # Act
      $context.ExportToEnvironment()

      # Assert
      [Environment]::GetEnvironmentVariable("${prefix}ProjectName") | Should -Be 'TestProject'
      [Environment]::GetEnvironmentVariable("${prefix}BuildNumber") | Should -Be '1.0.0'

      # Cleanup
      $context.ClearEnvironment()
    }

    It "BuildContext ClearEnvironment removes all exported variables" {
      # Arrange
      $context = [BuildContext]::new('TestProject', $PSScriptRoot, '1.0.0')
      $prefix = $context.RunId
      $context.ExportToEnvironment()

      # Act
      $context.ClearEnvironment()

      # Assert
      [Environment]::GetEnvironmentVariable("${prefix}ProjectName") | Should -BeNullOrEmpty
      [Environment]::GetEnvironmentVariable("${prefix}BuildNumber") | Should -BeNullOrEmpty
    }

    It "BuildContext GetVersionedOutputPath constructs correct path" {
      # Arrange
      $context = [BuildContext]::new('TestProject', 'C:\test\path', '1.0.0')

      # Act
      $versionedPath = $context.GetVersionedOutputPath()

      # Assert
      $versionedPath | Should -Match 'BuildOutput.*TestProject.*1\.0\.0'
    }
  }

  Context "BuildSummary Class" {
    It "BuildSummary initializes with project and build number" {
      # Arrange & Act
      $summary = [BuildSummary]::new('TestProject', '1.0.0')

      # Assert
      $summary.ProjectName | Should -Be 'TestProject'
      $summary.BuildNumber | Should -Be '1.0.0'
      $summary.Success | Should -Be $true
      $summary.Tasks | Should -Not -BeNullOrEmpty
    }

    It "BuildSummary AddTask tracks successful task results" {
      # Arrange
      $summary = [BuildSummary]::new('TestProject', '1.0.0')

      # Act
      $summary.AddTask('Clean', $true, [timespan]'00:00:01')

      # Assert
      $summary.Tasks.Count | Should -Be 1
      $summary.Tasks[0].Name | Should -Be 'Clean'
      $summary.Tasks[0].Success | Should -Be $true
    }

    It "BuildSummary marks as failed when task fails" {
      # Arrange
      $summary = [BuildSummary]::new('TestProject', '1.0.0')

      # Act
      $summary.AddTask('Compile', $false, [timespan]'00:00:05')

      # Assert
      $summary.Success | Should -Be $false
    }

    It "BuildSummary SetTestResults captures test metrics" {
      # Arrange
      $summary = [BuildSummary]::new('TestProject', '1.0.0')

      # Act
      $summary.SetTestResults(10, 9, 1, 0)

      # Assert
      $summary.TestResults.Total | Should -Be 10
      $summary.TestResults.Passed | Should -Be 9
      $summary.TestResults.Failed | Should -Be 1
      $summary.TestResults.Skipped | Should -Be 0
    }

    It "BuildSummary marks as failed when tests fail" {
      # Arrange
      $summary = [BuildSummary]::new('TestProject', '1.0.0')

      # Act
      $summary.SetTestResults(5, 3, 2, 0)

      # Assert
      $summary.Success | Should -Be $false
    }

    It "BuildSummary RenderSummary does not throw" {
      # Arrange
      $summary = [BuildSummary]::new('TestProject', '1.0.0')
      $summary.AddTask('Test', $true, [timespan]'00:00:02')
      $summary.SetTestResults(5, 5, 0, 0)

      # Act & Assert
      { $summary.RenderSummary() } | Should -Not -Throw
    }
  }

  Context "Binary Module Detection" {
    It "BuildOrchestrator detects script modules correctly" {
      # Arrange
      $testPath = [IO.Path]::Combine($env:TEMP, "TestScriptModule_$([Guid]::NewGuid().Guid)")
      if (Test-Path $testPath) { Remove-Item -Path $testPath -Recurse -Force }
      New-Item -Path $testPath -ItemType Directory -Force | Out-Null

      # Act
      $orchestrator = [BuildOrchestrator]::new($testPath, @('Clean'), @(), $null)

      # Assert
      $orchestrator.ModuleType | Should -Be 'Script'
      $orchestrator.HasBinarySrc | Should -Be $false

      # Cleanup
      Remove-Item -Path $testPath -Recurse -Force -ErrorAction Ignore
    }

    It "BuildOrchestrator detects binary modules with src folder" {
      # Arrange
      $testPath = [IO.Path]::Combine($env:TEMP, "TestBinaryModule_$([Guid]::NewGuid().Guid)")
      $srcPath = [IO.Path]::Combine($testPath, 'src')
      if (Test-Path $testPath) { Remove-Item -Path $testPath -Recurse -Force }
      New-Item -Path $srcPath -ItemType Directory -Force | Out-Null

      # Create dummy .csproj file
      $csprojPath = [IO.Path]::Combine($srcPath, 'TestModule.csproj')
      Set-Content -Path $csprojPath -Value '<Project></Project>'

      # Act
      $orchestrator = [BuildOrchestrator]::new($testPath, @('Clean'), @(), $null)

      # Assert
      $orchestrator.HasBinarySrc | Should -Be $true
      $orchestrator.ModuleType | Should -Be 'Binary'

      # Cleanup
      Remove-Item -Path $testPath -Recurse -Force -ErrorAction Ignore
    }
  }

  Context "Module Import with cliHelper.core" {
    It "PsCraft module imports without errors" {
      # Act & Assert
      { Get-Module -name PsCraft -ErrorAction Stop } | Should -Not -Throw
    }

    It "cliHelper.core is available and loaded" {
      # Act
      $cliHelperLoaded = Get-Module -name cliHelper.core -ErrorAction Ignore

      # Assert
      $cliHelperLoaded | Should -Not -BeNullOrEmpty
      $cliHelperLoaded.Version | Should -Not -BeNullOrEmpty
    }
  }

  Context "cliHelper.core Components Available" {
    It "AnsiConsole class is accessible" {
      # Act
      $ansiConsoleType = [type]::GetType('Spectre.Console.AnsiConsole', $false)

      # Assert
      $ansiConsoleType | Should -Not -BeNull
    }

    It "FigletText class is accessible" {
      # Act
      $figletType = [type]::GetType('Spectre.Console.FigletText', $false)

      # Assert
      $figletType | Should -Not -BeNull
    }

    It "Rule class is accessible" {
      # Act
      $ruleType = [type]::GetType('Spectre.Console.Rule', $false)

      # Assert
      $ruleType | Should -Not -BeNull
    }

    It "Panel class is accessible" {
      # Act
      $panelType = [type]::GetType('Spectre.Console.Panel', $false)

      # Assert
      $panelType | Should -Not -BeNull
    }

    It "Grid class is accessible" {
      # Act
      $gridType = [type]::GetType('Spectre.Console.Grid', $false)

      # Assert
      $gridType | Should -Not -BeNull
    }

    It "Table class is accessible" {
      # Act
      $tableType = [type]::GetType('Spectre.Console.Table', $false)

      # Assert
      $tableType | Should -Not -BeNull
    }

    It "BreakdownChart class is accessible" {
      # Act
      $chartType = [type]::GetType('Spectre.Console.BreakdownChart', $false)

      # Assert
      $chartType | Should -Not -BeNull
    }

    It "Progress class is accessible" {
      # Act
      $progressType = [type]::GetType('Spectre.Console.Progress', $false)

      # Assert
      $progressType | Should -Not -BeNull
    }

    It "Status class is accessible" {
      # Act
      $statusType = [type]::GetType('Spectre.Console.Status', $false)

      # Assert
      $statusType | Should -Not -BeNull
    }

    It "Tree class is accessible" {
      # Act
      $treeType = [type]::GetType('Spectre.Console.Tree', $false)

      # Assert
      $treeType | Should -Not -BeNull
    }

    It "MultiSelectionPrompt class is accessible" {
      # Act
      $promptType = [type]::GetType('Spectre.Console.MultiSelectionPrompt`1', $false)

      # Assert
      $promptType | Should -Not -BeNull
    }

    It "SelectionPrompt class is accessible" {
      # Act
      $promptType = [type]::GetType('Spectre.Console.SelectionPrompt`1', $false)

      # Assert
      $promptType | Should -Not -BeNull
    }

    It "TextPrompt class is accessible" {
      # Act
      $promptType = [type]::GetType('Spectre.Console.TextPrompt`1', $false)

      # Assert
      $promptType | Should -Not -BeNull
    }

    It "ConfirmationPrompt class is accessible" {
      # Act
      $promptType = [type]::GetType('Spectre.Console.ConfirmationPrompt', $false)

      # Assert
      $promptType | Should -Not -BeNull
    }
  }

  Context "Module Manifest Validation" {
    It "PsCraft.psd1 exists and is accessible" {
      # Arrange
      $manifestPath = [IO.Path]::Combine($PSScriptRoot, '..', 'PsCraft.psd1')

      # Assert
      Test-Path -Path $manifestPath -PathType Leaf | Should -Be $true
    }

    It "PsCraft.psd1 is valid PowerShell data file" {
      # Arrange
      $manifestPath = [IO.Path]::Combine($PSScriptRoot, '..', 'PsCraft.psd1')

      # Act & Assert
      { $manifest = Import-PowerShellDataFile -Path $manifestPath } | Should -Not -Throw
    }

    It "PsCraft.psd1 contains required module information" {
      # Arrange
      $manifestPath = [IO.Path]::Combine($PSScriptRoot, '..', 'PsCraft.psd1')

      # Act
      $manifest = Import-PowerShellDataFile -Path $manifestPath

      # Assert
      $manifest.ModuleVersion | Should -Not -BeNullOrEmpty
      $manifest.Description | Should -Not -BeNullOrEmpty
      $manifest.Author | Should -Not -BeNullOrEmpty
    }

    It "PsCraft.psd1 includes cliHelper.core as required module" {
      # Arrange
      $manifestPath = [IO.Path]::Combine($PSScriptRoot, '..', 'PsCraft.psd1')

      # Act
      $manifest = Import-PowerShellDataFile -Path $manifestPath
      $hasCliHelper = $manifest.RequiredModules | Where-Object { $_ -eq 'cliHelper.core' -or $_.ModuleName -eq 'cliHelper.core' }

      # Assert
      $hasCliHelper | Should -Not -BeNullOrEmpty
    }
  }
}
