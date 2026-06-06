# Tests for Module Types (Binary, Manifest, Cim)
#Requires -Modules Pester

Describe "Module Types: PsCraft" {
  BeforeAll {
    # Import required modules
    Import-Module -Name cliHelper.core -Verbose:$false -Force -ErrorAction Stop
    $manifestPath = [IO.Path]::Combine($PSScriptRoot, '..', 'PsCraft.psd1')
    Import-Module -Name $manifestPath -Verbose:$false -Force -ErrorAction Stop

    # Create temporary test directory
    $script:TestRoot = [IO.Path]::Combine($env:TEMP, "PsCraft_ModuleTypes_$([Guid]::NewGuid().Guid)")
    New-Item -Path $TestRoot -ItemType Directory -Force | Out-Null
  }

  AfterAll {
    if (Test-Path -Path $TestRoot) {
      Remove-Item -Path $TestRoot -Recurse -Force -ErrorAction Ignore
    }
  }

  Context "Manifest Module Creation" {
    It "Creates manifest module and validates structure" {
      $moduleName = 'TestManifestModule'
      $modulePath = [IO.Path]::Combine($TestRoot, 'manifest')
      New-Item -Path $modulePath -ItemType Directory -Force | Out-Null

      Push-Location $modulePath
      try {
        $module = [PsModule]::Create($moduleName, 'Manifest')
        $module.Save()

        $moduleFolderPath = [IO.Path]::Combine($modulePath, $moduleName)
        # Verify Manifest-specific files
        [IO.File]::Exists([IO.Path]::Combine($moduleFolderPath, "$moduleName.psd1")) | Should -Be $true
        # Verify NO .psm1 is created for Manifest module
        [IO.File]::Exists([IO.Path]::Combine($moduleFolderPath, "$moduleName.psm1")) | Should -Be $false
      } finally {
        Pop-Location
      }
    }
  }

  Context "Binary Module Creation" {
    It "Creates binary module and validates structure" {
      $moduleName = 'TestBinaryModule'
      $modulePath = [IO.Path]::Combine($TestRoot, 'binary')
      New-Item -Path $modulePath -ItemType Directory -Force | Out-Null

      Push-Location $modulePath
      try {
        $module = [PsModule]::Create($moduleName, 'Binary')
        $module.Save()

        $moduleFolderPath = [IO.Path]::Combine($modulePath, $moduleName)
        # Verify Binary-specific files
        [IO.File]::Exists([IO.Path]::Combine($moduleFolderPath, "$moduleName.psd1")) | Should -Be $true
        [IO.File]::Exists([IO.Path]::Combine($moduleFolderPath, 'src', "$moduleName.csproj")) | Should -Be $true
        [IO.File]::Exists([IO.Path]::Combine($moduleFolderPath, 'src', "GetInfoCmdlet.cs")) | Should -Be $true
      } finally {
        Pop-Location
      }
    }
  }

  Context "Cim Module Creation" {
    It "Creates cim module and validates structure" {
      $moduleName = 'TestCimModule'
      $modulePath = [IO.Path]::Combine($TestRoot, 'cim')
      New-Item -Path $modulePath -ItemType Directory -Force | Out-Null

      Push-Location $modulePath
      try {
        $module = [PsModule]::Create($moduleName, 'Cim')
        $module.Save()

        $moduleFolderPath = [IO.Path]::Combine($modulePath, $moduleName)
        # Verify Cim-specific files
        [IO.File]::Exists([IO.Path]::Combine($moduleFolderPath, "$moduleName.psd1")) | Should -Be $true
        [IO.File]::Exists([IO.Path]::Combine($moduleFolderPath, 'Cim', "$moduleName.cdxml")) | Should -Be $true
      } finally {
        Pop-Location
      }
    }
  }
}
