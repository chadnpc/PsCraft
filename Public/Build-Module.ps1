function Build-Module {
  # .SYNOPSIS
  #    Module buildScript with interactive workflow support
  # .DESCRIPTION
  #    A custom Psake buildScript for any module that was created by PsCraft.
  #    Core logic lives in [BuildOrchestrator]. This cmdlet is a thin parameter
  #    wrapper that delegates everything to the class.
  #    When run without parameters, prompts interactively for task selection.
  # .EXAMPLE
  #    Build-Module                # Interactive task selection
  #    Build-Module Test           # Run Test task
  #    Build-Module Deploy         # Run Deploy task with confirmation
  # .LINK
  #    https://github.com/chadnpc/PsCraft/blob/main/public/Build-Module.ps1
  [cmdletbinding(DefaultParameterSetName = 'task', SupportsShouldProcess)]
  param(
    [parameter(Mandatory = $false, Position = 0, ParameterSetName = 'task')]
    [ValidateScript({
        if ($null -eq $_) { return $true } # Allow null for interactive prompt
        $task_seq = [string[]]$_; $IsValid = $true
        $Tasks = @('Clean', 'Compile', 'Test', 'Deploy')
        foreach ($name in $task_seq) { $IsValid = $IsValid -and ($name -in $Tasks) }
        if ($IsValid) { return $true }
        throw [System.ArgumentException]::new('Task', "ValidSet: $($Tasks -join ', ').")
      })][Alias('t')]
    [string[]]$Task,

    [Parameter(Mandatory = $false, Position = 1, ParameterSetName = 'task')]
    [ValidateScript({
        if (Test-Path -Path $_ -PathType Container -ea Ignore) { return $true }
        throw [System.ArgumentException]::new('Path', "Path: $_ is not a valid directory.")
      })][Alias('p')]
    [string]$Path = (Resolve-Path .).Path,

    [Parameter(Mandatory = $false, ParameterSetName = 'task')]
    [string[]]$RequiredModules = @(),

    [Parameter(Mandatory = $false, ParameterSetName = 'task')]
    [Alias('u')][ValidateNotNullOrWhiteSpace()]
    [string]$gitUser,

    [parameter(ParameterSetName = 'task')]
    [Alias('i')]
    [switch]$Import,

    [parameter(ParameterSetName = 'help')]
    [Alias('h', '-help')]
    [switch]$Help
  )

  process {
    $orchestrator = [BuildOrchestrator]::new($Path, $Task, $RequiredModules, $PSCmdlet)
    if ($PSCmdlet.ShouldProcess("$Path", "Build module ($($Task -join ', '))")) {
      return $orchestrator.Run($Task)
    }
  }
}
