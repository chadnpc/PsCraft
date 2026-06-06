$script:ModuleName = (Get-Item "$PSScriptRoot/..").Name
$script:ModulePath = Resolve-Path "$PSScriptRoot/../BuildOutput/$ModuleName" | Get-Item
$script:moduleVersion = ((Get-ChildItem $ModulePath).Where({ $_.Name -as 'version' -is 'version' }).Name -as 'version[]' | Sort-Object -Descending)[0].ToString()

Describe "Manifest Module tests for $ModuleName" {
    Context "Verification of Manifest" {
        It "Should load the manifest file without errors" {
            $manifest = Import-PowerShellDataFile -Path "$ModulePath/$moduleVersion/$ModuleName.psd1"
            $manifest | Should -Not -BeNullOrEmpty
        }

        It "Should contain ModuleVersion" {
            $manifest = Import-PowerShellDataFile -Path "$ModulePath/$moduleVersion/$ModuleName.psd1"
            $manifest.ModuleVersion | Should -Not -BeNullOrEmpty
        }
    }
}
