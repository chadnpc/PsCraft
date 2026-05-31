using namespace System.IO
using namespace System.Collections.Generic
using namespace System.Collections.ObjectModel
using namespace System.Management.Automation.Language

class PsModuleData : Dictionary[string, Object] {
  [ValidateNotNullOrWhiteSpace()][string]$Name
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$Path
  [ReadOnlyCollection[ModuleFile]]$Files;
  [ReadOnlyCollection[ModuleFolder]]$Folders;
  static [hashtable]$ModuleSchema = (Read-ModuleData PsModuleBase DefaultModuleSchema);

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