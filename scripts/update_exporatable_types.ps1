# return a string of types to export, comma separated
$typesToExportSTR = (Get-ChildItem *.psm1 -Recurse -File | ForEach-Object {
    [IO.File]::ReadAllLines((Get-Item $_.FullName)).Where({
        $_.StartsWith("class") -or $_.StartsWith("enum ")
      }
    ).ForEach({
        $_.Replace("class ", '[').Replace("enum ", '[')
      }
    ).ForEach({
        ($_ -like "* : *") ? $_.split(" : ")[0] + ']' : $_.Replace(' {', ']')
      }
    )
  }
) -join ', '
$rootmodule = (Get-Item "PsCraft.psm1").FullName
$l = [IO.File]::ReadAllLines($rootmodule)
$lines = @(); $i = 0; $L | ForEach-Object { $lines += @{ i = $i; c = $_ }; $i++ }
[int]$b = $lines.Where({ $_.c.StartsWith('$typestoExport = @(') }).i
[int]$e = $l.Count - 1
$result = ($lines.c[0..$b] + $typesToExportSTR.TrimStart() + $lines.c[($b + 2)..$e]) -join [Environment]::NewLine
$result | Set-Content $rootmodule