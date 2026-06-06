$script:ModuleName = (Get-Item "$PSScriptRoot/..").Name
$script:ModulePath = Resolve-Path "$PSScriptRoot/../BuildOutput/$ModuleName" | Get-Item
$script:moduleVersion = ((Get-ChildItem $ModulePath).Where({ $_.Name -as 'version' -is 'version' }).Name -as 'version[]' | Sort-Object -Descending)[0].ToString()

Describe "CIM Module tests for $ModuleName" {
    BeforeAll {
        Get-Module -Name $ModuleName | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module -Name "$ModulePath/$moduleVersion/$ModuleName.psd1" -Force -ErrorAction Stop
    }

    AfterAll {
        Get-Module -Name $ModuleName | Remove-Module -Force -ErrorAction SilentlyContinue
    }

    Context "Verification of CIM Cmdlets" {
        It "Should export Get-OperatingSystem cmdlet" {
            Get-Command -Module $ModuleName | Select-Object -ExpandProperty Name | Should -Contain "Get-OperatingSystem"
        }

        It "Should run Get-OperatingSystem cmdlet successfully" {
            if ($IsWindows -or $env:OS -match "Windows") {
                $result = Get-OperatingSystem
                $result | Should -Not -BeNullOrEmpty
            }
        }
    }
}
