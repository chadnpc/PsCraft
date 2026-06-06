$script:ModuleName = (Get-Item "$PSScriptRoot/..").Name
$script:ModulePath = Resolve-Path "$PSScriptRoot/../BuildOutput/$ModuleName" | Get-Item
$script:moduleVersion = ((Get-ChildItem $ModulePath).Where({ $_.Name -as 'version' -is 'version' }).Name -as 'version[]' | Sort-Object -Descending)[0].ToString()

Describe "Binary Module tests for $ModuleName" {
    BeforeAll {
        Get-Module -Name $ModuleName | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module -Name "$ModulePath/$moduleVersion/$ModuleName.psd1" -Force -ErrorAction Stop
    }

    AfterAll {
        Get-Module -Name $ModuleName | Remove-Module -Force -ErrorAction SilentlyContinue
    }

    Context "Verification of Cmdlets" {
        It "Should export Get-Info cmdlet" {
            Get-Command -Module $ModuleName | Select-Object -ExpandProperty Name | Should -Contain "Get-Info"
        }

        It "Should run Get-Info cmdlet successfully" {
            $result = Get-Info
            $result | Should -Be "Hello from $ModuleName binary module!"
        }
    }
}
