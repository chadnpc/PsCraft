
<#PSScriptInfo

.VERSION 0.1.0

.GUID e9a8524e-3c3f-4d88-af66-bf57f104c339

.AUTHOR Alain Herve

.COMPANYNAME chadnpc

.COPYRIGHT chadnpc

.TAGS PowershelGallery

.LICENSEURI

.PROJECTURI https://github.com/chadnpc/PsCraft

.ICONURI

.EXTERNALMODULEDEPENDENCIES

.REQUIREDSCRIPTS ./build.ps1

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES


.PRIVATEDATA

#>
# .DESCRIPTION
#  Publish Script,
#  All it does is decrypt the env and passes it as arg to build script
Param()

# $BuildScript = [IO.Path]::Combine($PSScriptRoot, 'build.ps1')
$NugetApiKey = $Env:NUGETAPIKEY
if (!$Env:GITHUB_ACTION_PATH) {
  # Means, We are on local pc so we'll have to decrypt the env variable
  $private:AESKey = $null; Set-Variable -Name AESKey -Value ([AzureHSM]::New().RetrieveKey()) -Option ReadOnly -Visibility Private
  $apiPrompt_text = "Enter your NUGET APIKEY"
  $private:UsrNpt = $null; Set-Variable -Name UsrNpt -Scope Local -Visibility Private -Option Private -Value $(if ([System.Environment]::OSVersion.Platform -in ('Win32NT', 'Win32S', 'Win32Windows', 'WinCE')) {
      [AzureHSM]::ConvertToSecureString([scriptblock]::Create("$((Invoke-RestMethod -Method Get https://api.github.com/gists/b12ce490d427a917d3d6a24f71180f7e).files.'SecureText-Prompt-Gui.ps1'.content)").Invoke($apiPrompt_text))
    } else {
      Read-Host -AsSecureString -Prompt $apiPrompt_text
    }
  )
  if (![regex]::IsMatch($NugetApiKey, '^(?=.{100,})(?=.*0{2,})')) {
    Set-Item -Path ([IO.Path]::Combine('Env:', 'NUGETAPIKEY')) -Value $(ConvertFrom-SecureString -SecureString $usrNpt -Key $AESKey) -Force
  }; $NugetApiKey = [system.Management.Automation.PSCredential]::New("test", $(ConvertTo-SecureString $Env:NUGETAPIKEY -Key $AESKey)).GetNetworkCredential().Password
}
Write-Host "Your NugetApiKey: $NugetApiKey" -ForegroundColor Magenta
# & $BuildScript -Task Deploy -ApiKey $NugetApiKey
exit $?