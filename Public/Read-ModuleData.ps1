function Read-ModuleData {
  # .SYNOPSIS
  #   Reads a specific value from a PowerShell metdata file (e.g. a module manifest)
  # .DESCRIPTION
  #   By default Get-ModuleManifest gets all keys in the metadata file
  # .LINK
  #   https://github.com/chadnpc/PsCraft/blob/main/Public/Read-ModuleData.ps1
  # .EXAMPLE
  #   Read-ModuleData .
  #   Reads the Moduledata from the current directory, assumes that the module name is the same as the directory name
  [CmdletBinding(ConfirmImpact = 'None')]
  [OutputType([PsObject])]
  param (
    [Parameter(Position = 0, Mandatory = $false, ValueFromPipeline = $true)]
    [ValidateNotNullOrWhiteSpace()][Alias('f')][string]
    $File,

    [Parameter(Position = 1, Mandatory = $false)]
    [AllowNull()][string]
    $Property,

    [Parameter(Position = 2, Mandatory = $false)]
    [ValidateScript({
        $p = (Resolve-Path $_ -ea Ignore)
        if ((Test-Path -Path $p -PathType Container -ea Ignore)) {
          return $true
        } else {
          throw [System.ArgumentException]::new("directory '$_' does not exist.", 'Path')
        }
      }
    )][string]
    $Path = (Get-Location).Path,

    [switch]$NoNullResult
  )
  begin {
    if (![IO.Directory]::Exists($Path)) { [string]$Path = Resolve-Path $Path -ea Stop }
    if (!$PSCmdlet.MyInvocation.BoundParameters.ContainsKey('File')) {
      $File = [IO.Path]::Combine($Path, (Get-Culture).Name, "$([IO.DirectoryInfo]::New($Path).BaseName).strings.psd1");
    }; $File = Resolve-Path $File;
    $IsValidPsd1file = (Test-Path -Path $File -PathType Leaf -ea Ignore) -and ([IO.Path]::GetExtension($File) -eq ".psd1")
    if (!$IsValidPsd1file) {
      throw [System.ArgumentException]::new("File '$File' is not valid. Please provide a valid path/to/<modulename>.Strings.psd1", 'Path')
    }
    if (!(Test-Path $File)) {
      $Error_params = @{
        ExceptionName    = "System.IO.FileNotFoundException"
        ExceptionMessage = "Can't find file $File"
        ErrorId          = "PathNotFound,Metadata\Import-Metadata"
        Caller           = $PSCmdlet
        ErrorCategory    = "ObjectNotFound"
      }
      Write-TerminatingError @Error_params
    }
  }
  process {
    $data = New-Object PsObject; $text = [IO.File]::ReadAllText($File)
    $data = [scriptblock]::Create("$text").Invoke()
    if ([string]::IsNullOrWhiteSpace($Property)) { return $data }
    $_res = $data.$Property
    if ($null -eq $_res -and $NoNullResult) {
      $Error_params = @{
        ExceptionName    = "System.Management.Automation.ItemNotFoundException"
        ExceptionMessage = "Can't find '$Property' in $File"
        ErrorId          = "PropertyNotFound,Metadata\Get-Metadata"
        Caller           = $PSCmdlet
        ErrorCategory    = "ObjectNotFound"
      }
      Write-TerminatingError @Error_params
    }
    return $_res
  }
}