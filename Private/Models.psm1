using namespace System.IO
using namespace System.Collections.Generic
using namespace System.Management.Automation.Language
using namespace System.Management.Automation
using namespace System.Collections.ObjectModel

using module .\Enums.psm1

class ParseResult {
  [Token[]]$Tokens
  [ScriptBlockAst]$AST
  [ParseError[]]$ParseErrors

  ParseResult([ParseError[]]$Errors, [Token[]]$Tokens, [ScriptBlockAst]$AST) {
    $this.ParseErrors = $Errors
    $this.Tokens = $Tokens
    $this.AST = $AST
  }
}

class AliasVisitor : System.Management.Automation.Language.AstVisitor {
  [string]$Parameter = $null
  [string]$Command = $null
  [string]$Name = $null
  [string]$Value = $null
  [string]$Scope = $null
  [System.Collections.Generic.HashSet[string]]$Aliases = @()

  # Parameter Names
  [System.Management.Automation.Language.AstVisitAction] VisitCommandParameter([System.Management.Automation.Language.CommandParameterAst]$ast) {
    $this.Parameter = $ast.ParameterName
    return [System.Management.Automation.Language.AstVisitAction]::Continue
  }

  # Parameter Values
  [System.Management.Automation.Language.AstVisitAction] VisitStringConstantExpression([System.Management.Automation.Language.StringConstantExpressionAst]$ast) {
    # The FIRST command element is always the command name
    if (!$this.Command) {
      $this.Command = $ast.Value
      return [System.Management.Automation.Language.AstVisitAction]::Continue
    } else {
      # Nobody should use minimal parameters like -N for -Name ...
      # But if they do, our parser works anyway!
      switch -Wildcard ($this.Parameter) {
        "S*" {
          $this.Scope = $ast.Value
        }
        "N*" {
          $this.Name = $ast.Value
        }
        "Va*" {
          $this.Value = $ast.Value
        }
        "F*" {
          if ($ast.Value) {
            # Force parameter was passed as named parameter with a positional parameter after it which is alias name
            $this.Name = $ast.Value
          }
        }
        default {
          if (!$this.Parameter) {
            # For bare arguments, the order is Name, Value:
            if (!$this.Name) {
              $this.Name = $ast.Value
            } else {
              $this.Value = $ast.Value
            }
          }
        }
      }
      $this.Parameter = $null
      # If we have enough information, stop the visit
      # For -Scope global or Remove-Alias, we don't want to export these
      if ($this.Name -and $this.Command -eq "Remove-Alias") {
        $this.Command = "Remove-Alias"
        return [System.Management.Automation.Language.AstVisitAction]::StopVisit
      } elseif ($this.Name -and $this.Scope -eq "Global") {
        return [System.Management.Automation.Language.AstVisitAction]::StopVisit
      }
      return [System.Management.Automation.Language.AstVisitAction]::Continue
    }
  }

  # The [Alias(...)] attribute on functions matters, but we can't export aliases that are defined inside a function
  [System.Management.Automation.Language.AstVisitAction] VisitFunctionDefinition([System.Management.Automation.Language.FunctionDefinitionAst]$ast) {
    @($ast.Body.ParamBlock.Attributes.Where{ $_.TypeName.Name -eq "Alias" }.PositionalArguments.Value).ForEach{
      if ($_) {
        $this.Aliases.Add($_)
      }
    }
    return [System.Management.Automation.Language.AstVisitAction]::SkipChildren
  }

  # Top-level commands matter, but only if they're alias commands
  [System.Management.Automation.Language.AstVisitAction] VisitCommand([System.Management.Automation.Language.CommandAst]$ast) {
    if ($ast.CommandElements[0].Value -imatch "(New|Set|Remove)-Alias") {
      $ast.Visit($this.ClearParameters())
      $Params = $this.GetParameters()
      # We COULD just remove it (even if we didn't add it) ...
      if ($Params.Command -ieq "Remove-Alias") {
        # But Write-Verbose for logging purposes
        if ($this.Aliases.Contains($this.Parameters.Name)) {
          Write-Verbose -Message "Alias '$($Params.Name)' is removed by line $($ast.Extent.StartLineNumber): $($ast.Extent.Text)"
          $this.Aliases.Remove($Params.Name)
        }
        # We don't need to export global aliases, because they broke out already
      } elseif ($Params.Name -and $Params.Scope -ine 'Global') {
        $this.Aliases.Add($this.Parameters.Name)
      }
    }
    return [System.Management.Automation.Language.AstVisitAction]::SkipChildren
  }
  [PSCustomObject] GetParameters() {
    return [PSCustomObject]@{
      PSTypeName = "PsCraft.AliasVisitor.AliasParameters"
      Name       = $this.Name
      Command    = $this.Command
      Parameter  = $this.Parameter
      Value      = $this.Value
      Scope      = $this.Scope
    }
  }
  [AliasVisitor] ClearParameters() {
    $this.Command = $null
    $this.Parameter = $null
    $this.Name = $null
    $this.Value = $null
    $this.Scope = $null
    return $this
  }
}

class PsModuleData : Dictionary[string, Object] {
  [ValidateNotNullOrWhiteSpace()][string]$Name
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$Path
  [ReadOnlyCollection[ModuleFile]]$Files
  [ReadOnlyCollection[ModuleFolder]]$Folders
  static [hashtable]$ModuleSchema = (Read-ModuleData PsModuleBase DefaultModuleSchema)

  PsModuleData() {}
  # PsModuleData([hashtable]$data) {}
  PsModuleData([string]$Name, [IO.DirectoryInfo]$Path) {
    $this.Name = [string]::IsNullOrWhiteSpace($Name) ? [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetRandomFileName()) : $Name
    [string]$mroot = switch ($true) {
      $(![string]::IsNullOrWhiteSpace($Path.FullName)) {
        $Path.FullName;
        break
      }
      $(![string]::IsNullOrEmpty($Path.FullName)) {
        $fp = ([Path]::GetFileNameWithoutExtension($Path.FullName) -ne $this.Name) ? [FileInfo][Path]::Combine(([Path]::GetDirectoryName($Path.FullName) | Split-Path), "$($this.Name).psd1") : $Path.FullName
        [Path]::GetDirectoryName($fp)
        break
      }
      default { (Resolve-Path .).Path }
    }
    $this.Path = [Path]::Combine([PsModuleBase]::GetunResolvedPath($mroot), $this.Name); [void][PsModuleBase]::validatePath($this.Path);
    $this.Files = [PsModuleData]::GetModuleFiles($this.Name, $this.Path)
    $this.Folders = [PsModuleData]::GetModuleSubFolders($this.Path)
  }
  PsModuleData([string]$Name, [ModuleFile[]]$Files, [ModuleFolder[]]$Folders) {
    $this.Name = $Name
    $this.Files = New-ReadOnlyCollection -list $Files
    $this.Folders = New-ReadOnlyCollection -list $Folders
  }
  static [ReadOnlyCollection[ModuleFile]] GetModuleFiles([string]$ModName, [string]$ModRoot) {
    [ValidateNotNullOrWhiteSpace()][string]$ModRoot = $ModRoot
    [ValidateNotNullOrWhiteSpace()][string]$ModName = $ModName
    $l = @(); [PsModuleData]::ModuleSchema.Files.GetEnumerator().ForEach({
        $l += [ModuleFile]::new($_.Name, $_.Value.replace('./', $ModRoot).replace('{mName}', $ModName))
      }
    )
    return New-ReadOnlyCollection -list $l
  }
  static [ReadOnlyCollection[ModuleFolder]] GetModuleSubFolders([string]$ModRoot) {
    [ValidateNotNullOrWhiteSpace()][string]$ModRoot = $ModRoot
    $l = @(); [PsModuleData]::ModuleSchema.Folders.GetEnumerator().ForEach({
        $l += [ModuleFolder]::new($_.Name, [IO.Path]::Combine($ModRoot, $_.Value.replace('./', '')))
      }
    )
    return New-ReadOnlyCollection -list $l
  }
  [void] SetModuleFile([string]$keyName, [string]$Path) {}
  # PsModuleData([array]$k_v_t) {
  #   if ($k_v_t.Count -eq 3) {
  #     [void][PsModuleData]::From([string]$k_v_t[0], $k_v_t[1], [Type]$k_v_t[2], [ref]$this)
  #   } elseif ($k_v_t.Count -eq 2) {
  #     [void][PsModuleData]::From([string]$k_v_t[0], $k_v_t[1], [ref]$this)
  #   } else {
  #     throw [TypeInitializationException]::new("PsModuleData", [ArgumentException]::new("New-Object PsModuleData([array]`$k_v_t) failed. k_v_t.count should be 3 or 2.", "key_value_type array"))
  #   }
  # }
  # [void] Add([string]$key, [ModuleItemType]$type, [Object]$value) {
  #   [ValidateNotNullOrWhiteSpace()]$key = $key; [ValidateNotNull()]$type = $type
  #   if ($type -eq "File") {
  #     $this.Files.Add([ModuleFile]::new($key, $value))
  #   } else {
  #     $this.Folders.Add([ModuleFolder]::new($key, $value))
  #   }
  # }
  [void] Set($Value) { $this.Value = $Value }
  [void] Format() {
    if ($this.Type.Name -in ('String', 'ScriptBlock')) {
      try {
        # Write-Host "FORMATTING: << $($this.Key) : $($this.Type.Name)" -f Blue -NoNewline
        $this.Value = Invoke-Formatter -ScriptDefinition $this.Value.ToString() -Verbose:$false
      } catch {
        # Write-Host " Attempt to format the file line by line. " -f Magenta -nonewline
        $content = $this.Value.ToString()
        $formattedLines = @()
        foreach ($line in $content) {
          try {
            $formattedLine = Invoke-Formatter -ScriptDefinition $line -Verbose:$false
            $formattedLines += $formattedLine
          } catch {
            # If formatting fails, keep the original line
            $formattedLines += $line
          }
        }
        $_value = [string]::Join([Environment]::NewLine, $formattedLines)
        if ($this.Type.Name -eq 'String') {
          $this.Value = $_value
        } elseif ($this.Type.Name -eq 'ScriptBlock') {
          $this.Value = [scriptblock]::Create("$_value")
        }
      }
      # Write-Host " done $($this.Key) >>" -f Green
    }
  }
  static [string] GetAuthorName([string]$ModuleName) {
    return Get-AuthorName -n $ModuleName
  }
  static [string] GetAuthorEmail([string]$ModuleName) {
    return Get-AuthorEmail -n $ModuleName
  }
  static [string] GetModuleReadmeText([string]$ModuleName) {
    return Get-ModuleReadmeText -n $ModuleName
  }
  static [string] GetModuleLicenseText([string]$ModuleName) {
    return Get-ModuleLicenseText -n $ModuleName
  }
  static [string] GetModuleCICDyaml([string]$ModuleName) {
    return Get-ModuleCICDyaml -n $ModuleName
  }
  static [string] GetModuleCodereviewyaml([string]$ModuleName) {
    return Get-ModuleCodereviewyaml -n $ModuleName
  }
  static [string] GetModulePublishyaml([string]$ModuleName) {
    return Get-ModulePublishyaml -n $ModuleName
  }
  static [string] GetModuleDelWorkflowsyaml([string]$ModuleName) {
    return Get-ModuleDelWorkflowsyaml -n $ModuleName
  }
  static [Collection[PsModuleData]] ReplaceTemplates([Collection[PsModuleData]]$data) {
    $templates = $data.Where({ $_.Type.Name -in ("String", "ScriptBlock") })
    $hashtable = @{}; $data.Foreach({ $hashtable += @{ $_.Key = $_.Value } }); $keys = $hashtable.Keys
    foreach ($item in $templates) {
      [string]$n = $item.Key
      [string]$t = $item.Type.Name
      if ([string]::IsNullOrWhiteSpace($n)) { Write-Warning "`$item.Key is empty"; continue }
      if ([string]::IsNullOrWhiteSpace($t)) { Write-Warning "`$item.Type.Name is empty"; continue }
      switch ($t) {
        'ScriptBlock' {
          if ($null -eq $hashtable[$n]) { break }
          $str = $hashtable[$n].ToString()
          $keys.ForEach({
              if ($str -match "<$_>") {
                $str = $str.Replace("<$_>", $hashtable["$_"])
                $item.Set([scriptblock]::Create($str))
                Write-Debug "`$module.data.$($item.Key) Replaced <$_>)"
              }
            }
          )
          break
        }
        'String' {
          if ($null -eq $hashtable[$n]) { break }
          $str = $hashtable[$n]
          $keys.ForEach({
              if ($str -match "<$_>") {
                $str = $str.Replace("<$_>", $hashtable["$_"])
                $item.Set($str)
                Write-Debug "`$module.data.$($item.Key) Replaced <$_>"
              }
            }
          )
          break
        }
        default {
          Write-Warning "Unknown Type: $t"
          continue
        }
      }
    }
    return $data
  }
  [string] ToString() {
    if ($this.Count -gt 0) {
      return "@({0})" -f [string]::Join(', ', $this.Files.Name)
    }
    return '@{}'
  }
}

class PsModule : IDisposable {
  [ValidateNotNullOrEmpty()] [String]$Name;
  [ValidateNotNullOrEmpty()] [IO.DirectoryInfo]$Path;
  [PsModuleData] $data;
  static [hashtable] $Config

  PsModule() {
    [PsModule]::Create($null, $null, [ref]$this)
  }
  PsModule([string]$Name) {
    [PsModule]::Create($Name, $null, [ref]$this)
  }
  PsModule([string]$Name, [IO.DirectoryInfo]$Path) {
    [PsModule]::Create($Name, $Path, [ref]$this)
  }
  static [PsModule] Create([string]$Name) { return [PsModule]::Create($Name, $null) }

  static [PsModule] Create([string]$Name, [string]$Path) {
    $b = [PsModuleBase]::GetunResolvedPath($Path); $p = [IO.Path]::Combine($b, $Name);
    $d = [IO.DirectoryInfo]::new($p); if (![IO.Directory]::Exists($d)) {
      return [PsModule]::new($d.BaseName, $d.Parent)
    }
    Write-Host "[WIP] Load Module from $p" -f Blue
    return [PsModule]::Load($d)
  }
  static hidden [PsModule] Create([string]$Name, [IO.DirectoryInfo]$Path, [ref]$o) {
    if ($null -eq $o.Value -and [PsModule]::_n) { [PsModule]::_n = $false; $n = [PsModule]::new(); $o = [ref]$n }
    if ($null -ne [PsModule]::Config) {
      # Config includes:
      # - Build steps
      # - Params ...
    }
    $o.Value.Name = [string]::IsNullOrWhiteSpace($Name) ? [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetRandomFileName()) : $Name
    ($mName, $_umroot) = [string]::IsNullOrWhiteSpace($Path.FullName) ? ($o.Value.Name, $Path.FullName) : ($o.Value.Name, "")
    $mroot = [Path]::Combine([PsModuleBase]::GetunResolvedPath($(
          switch ($true) {
            $(![string]::IsNullOrWhiteSpace($_umroot)) { $_umroot; break }
            $o.Value.Path {
              if ([Path]::GetFileNameWithoutExtension($o.Value.Path) -ne $mName) {
                $o.Value.Path = [FileInfo][Path]::Combine(([Path]::GetDirectoryName($o.Value.Path) | Split-Path), "$mName.psd1")
              }
              [Path]::GetDirectoryName($o.Value.Path);
              break
            }
            default { $(Resolve-Path .).Path }
          })
      ), $mName)
    [void][PsModuleBase]::validatePath($mroot); $o.Value.Path = $mroot
    $o.Value.Files = [List[ModuleFile]]::new()
    $o.Value.Folders = [List[ModuleFolder]]::new()
    $mtest = [Path]::Combine($mroot, 'Tests');
    $workflows = [Path]::Combine($mroot, '.github', 'workflows')
    $dr = @{
      root      = $mroot
      tests     = [Path]::Combine($mroot, 'Tests');
      public    = [Path]::Combine($mroot, 'Public')
      private   = [Path]::Combine($mroot, 'Private')
      LocalData = [Path]::Combine($mroot, (Get-Culture).Name) # The purpose of this folder is to store localized content for your module, such as help files, error messages, or any other text that needs to be displayed in different languages.
      workflows = $workflows
      # Add more here. you can access them like: $this.Folders.Where({ $_.Name -eq "root" }).value.FullName
    };
    $dr.Keys.ForEach({ $o.Value.Folders += [ModuleFolder]::new($_, $dr[$_]) })
    @{
      Path             = [Path]::Combine($mroot, "$mName.psd1")
      Tester           = [Path]::Combine($mroot, "Test-Module.ps1")
      Builder          = [Path]::Combine($mroot, "build.ps1")
      License          = [Path]::Combine($mroot, "LICENSE")
      Readme           = [Path]::Combine($mroot, "README.md")
      Manifest         = [Path]::Combine($mroot, "$mName.psd1")
      LocalData        = [Path]::Combine($dr["LocalData"], "$mName.strings.psd1")
      rootLoader       = [Path]::Combine($mroot, "$mName.psm1")
      ModuleTest       = [Path]::Combine($mtest, "$mName.Module.Tests.ps1")
      FeatureTest      = [Path]::Combine($mtest, "$mName.Features.Tests.ps1")
      ScriptAnalyzer   = [Path]::Combine($mroot, "PSScriptAnalyzerSettings.psd1")
      IntegrationTest  = [Path]::Combine($mtest, "$mName.Integration.Tests.ps1")
      DelWorkflowsyaml = [Path]::Combine($workflows, 'delete_old_workflow_runs.yaml')
      Codereviewyaml   = [Path]::Combine($workflows, 'codereview.yaml')
      Publishyaml      = [Path]::Combine($workflows, 'publish.yaml')
      GitIgnore        = [Path]::Combine($mroot, ".gitignore")
      CICDyaml         = [Path]::Combine($workflows, 'build_module.yaml')
      DotEnv           = [Path]::Combine($mroot, ".env")
      # Add more here
    }.GetEnumerator().ForEach({
        $o.Value.Files += [ModuleFile]::new($_.Name, $_.Value)
      }
    )
    $o.Value.Data = [PsModuleData]::Create($o.Value.Name, $o.Value.Path, $o.Value.Files)
    return $o.Value
  }
  [void] Save() {
    $this.Save([SaveOptions]::None)
  }
  [void] Save([SaveOptions]$Options) {
    if ([string]::IsNullOrWhiteSpace($this.Name)) {
      throw [System.ArgumentNullException]::New('$this.Name', "Make sure module Name is not empty")
    }
    $filestoFormat = $this.GetFiles().Where({ $_.Path.Extension -in ('.ps1', '.psd1', '.psm1') })
    $this.Data.Where({ $_.Key -in $filestoFormat.Name }).ForEach({ $_.Format() })
    $this.Data = [PsModuleData]::ReplaceTemplates($this.Data); $this.WritetoDisk($Options)
  }
  [void] Set([string]$Key, $Value) {
    $this.Data.Where({ $_.Key -eq $Key }).Set($Value);
  }
  [void] FormatCode() {
    $type = [type]"PsCraft"
    $type::FormatCode($this)
  }
  [void] WritetoDisk([SaveOptions]$Options) {
    $Force = $Options -eq [SaveOptions]::None
    $debug = $(Get-Variable debugPreference -ValueOnly) -eq "Continue"
    Write-Host "[+] Create Module Directories ... " -ForegroundColor Green -NoNewline:(!$debug -as [SwitchParameter])
    $this.Folders | ForEach-Object {
      $nF = @(); $p = $_.value; while (!$p.Exists) { $nF += $p; $p = $p.Parent }
      [Array]::Reverse($nF);
      foreach ($d in $nF) {
        New-Item -Path $d.FullName -ItemType Directory -Force:$Force
        if ($debug) { Write-Debug "Created Directory '$($d.FullName)'" }
      }
    }
    Write-Host "Done" -ForegroundColor Green

    Write-Host "[+] Create Module Files ... " -ForegroundColor Green -NoNewline:(!$debug -as [SwitchParameter])
    $this.GetFiles().ForEach({ [IO.File]::WriteAllText($_.Path, $_.Content, [System.Text.Encoding]::UTF8); if ($debug) { Write-Debug "Created $($_.Name)" } })
    $PM = @{}; $this.Data.Where({ $_.Attributes -contains "ManifestKey" }).ForEach({ $PM.Add($_.Key, $_.Value) })
    New-ModuleManifest @PM
    Write-Host "Done" -ForegroundColor Green
  }
  static [PsModule] Load([string]$Path) {
    return [PsModule]::Load($null, $Path)
  }
  static [PsModule] Load([string]$Name, [string]$Path) {
    # TODO: Add some Module Loading code Here
    throw "[PsModule]::Load(...) NOT IMPLEMENTED YET (WIP)"
  }
  [PsObject[]] GetFiles() {
    $KH = @{}; $this.Data.Where({ $_.Attributes -notcontains "ManifestKey" -and $_.Attributes -contains "FileContent" }).ForEach({ $KH[$_.Key] = $_.Value })
    $MF = $this.Files | Select-Object Name, @{l = "Path"; e = { $_.Value } }, @{l = "Content"; e = { $KH[$_.Name] } }
    return $MF
  }
  [void] Test() {
    # $this.Save()
    # .then run tests
    throw "`$psmodule.Test() is NOT IMPLEMENTED YET (WIP)"
  }
  [void] Publish() {
    $this.Publish('LocalRepo', [Path]::GetDirectoryName($Pwd))
  }
  [void] Publish($repoName, $repoPath) {
    if (Test-Path -Type Container -Path $repoPath -ErrorAction SilentlyContinue) {
      throw ""
    } else {
      New-Item -Path $repoPath -ItemType Directory | Out-Null
    }
    $this.Save()
    # If the PSrepo is not known, create one.
    if (![bool](Get-PSRepository "$repoName" -ErrorAction SilentlyContinue).Trusted) {
      $repoParams = @{
        Name               = $repoName
        SourceLocation     = $repoPath
        PublishLocation    = $repoPath
        InstallationPolicy = 'Trusted'
      }
      Register-PSRepository @repoParams
    }
    Publish-Module -Path $this.moduleDir -Repository $repoName
    Install-Module $this.Name -Repository $repoName
  }
  static [void] Publish ([string]$Path, [securestring]$ApiKey, [bool]$IncrementVersion ) {
    $moduleName = Split-Path $Path -Leaf
    $functions = Get-PsModuleFunctions $Path -PublicOnly
    if ($IncrementVersion) {
      $moduleFile = "$((Join-Path $path $moduleName)).psd1"
      $file = Import-PowerShellDataFile $moduleFile -Verbose:$false;
      [version]$version = ($file).ModuleVersion
      [version]$newVersion = "{0}.{1}.{2}" -f $version.Major, $version.Minor, ($version.Build + 1)
      Update-ModuleManifest -Path "$((Join-Path $Path $moduleName)).psd1" -FunctionsToExport $functions -ModuleVersion $newVersion;
    } else {
      Update-ModuleManifest -Path "$((Join-Path $Path $moduleName)).psd1" -FunctionsToExport $functions;
    }
    Publish-Module -Path $Path -NuGetApiKey $ApiKey;

    Write-Host "Module $moduleName Published " -f Green;
  }
  [void] Dispose() {
    if ($this.Path.Exists) { $this.Delete() }
  }
  [void] Delete() {
    Get-Module $this.Name | Remove-Module -Force -ErrorAction Ignore
    Remove-Item $this.Path.FullName -Recurse -Force
  }
}