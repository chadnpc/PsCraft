# Describes how to define methods for PowerShell classes.

Methods define the actions that a class can perform. Methods can take parameters that specify input data. Methods always define an output type. If a method doesn't return any output, it must have the **Void** output type. If a method doesn't explicitly define an output type, the method's output type is **Void**.

In class methods, no objects get sent to the pipeline except those specified in the `return` statement. There's no accidental output to the pipeline from the code.

Note

This is fundamentally different from how PowerShell functions handle output, where everything goes to the pipeline.

Nonterminating errors written to the error stream from inside a class method aren't passed through. You must use `throw` to surface a terminating error. Using the `Write-*` cmdlets, you can still write to PowerShell's output streams from within a class method. The cmdlets respect the [preference variables](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables?view=powershell-7.6) in the calling scope. However, you should avoid using the `Write-*` cmdlets so that the method only outputs objects using the `return` statement.

Class methods can reference the current instance of the class object by using the `$this` automatic variable to access properties and other methods defined in the current class. The `$this` automatic variable isn't available in static methods.

Class methods can have any number of attributes, including the [hidden](#hidden-methods) and [static](#static-methods) attributes.

Class methods use the following syntaxes:

Syntax

```Syntax
[[<attribute>]...] [hidden] [static] [<output-type>] <method-name> ([<method-parameters>]) { <body> }
```

Syntax

```Syntax
[[<attribute>]...]
[hidden]
[static]
[<output-type>] <method-name> ([<method-parameters>]) {
  <body>
}
```

The `GetVolume()` method of the **ExampleCube1** class returns the volume of the cube. It defines the output type as a floating number and returns the result of multiplying the **Height**, **Length**, and **Width** properties of the instance.

PowerShell

```powershell
class ExampleCube1 {
    [float]   $Height
    [float]   $Length
    [float]   $Width

    [float] GetVolume() { return $this.Height * $this.Length * $this.Width }
}

$box = [ExampleCube1]@{
    Height = 2
    Length = 2
    Width  = 3
}

$box.GetVolume()
```

Output

```Output
12
```

The `GeWeight()` method takes a floating number input for the density of the cube and returns the weight of the cube, calculated as volume multiplied by density.

PowerShell

```powershell
class ExampleCube2 {
    [float]   $Height
    [float]   $Length
    [float]   $Width

    [float] GetVolume() { return $this.Height * $this.Length * $this.Width }
    [float] GetWeight([float]$Density) {
        return $this.GetVolume() * $Density
    }
}

$cube = [ExampleCube2]@{
    Height = 2
    Length = 2
    Width  = 3
}

$cube.GetWeight(2.5)
```

Output

```Output
30
```

This example defines the `Validate()` method with the output type as **System.Void**. This method returns no output. Instead, if the validation fails, it throws an error. The `GetVolume()` method calls `Validate()` before calculating the volume of the cube. If validation fails, the method terminates before the calculation.

PowerShell

```powershell
class ExampleCube3 {
    [float]   $Height
    [float]   $Length
    [float]   $Width

    [float] GetVolume() {
        $this.Validate()

        return $this.Height * $this.Length * $this.Width
    }

    [void] Validate() {
        $InvalidProperties = @()
        foreach ($Property in @('Height', 'Length', 'Width')) {
            if ($this.$Property -le 0) {
                $InvalidProperties += $Property
            }
        }

        if ($InvalidProperties.Count -gt 0) {
            $Message = @(
                'Invalid cube properties'
                "('$($InvalidProperties -join "', '")'):"
                "Cube dimensions must all be positive numbers."
            ) -join ' '
            throw $Message
        }
    }
}

$Cube = [ExampleCube3]@{ Length = 1 ; Width = -1 }
$Cube

$Cube.GetVolume()
```

Output

```Output
Height Length Width
------ ------ -----
  0.00   1.00 -1.00

Exception:
Line |
  20 |              throw $Message
     |              ~~~~~~~~~~~~~~
     | Invalid cube properties ('Height', 'Width'): Cube dimensions must
     | all be positive numbers.
```

The method throws an exception because the **Height** and **Width** properties are invalid, preventing the class from calculating the current volume.

The **ExampleCube4** class defines the static method `GetVolume()` with two overloads. The first overload has parameters for the dimensions of the cube and a flag to indicate whether the method should validate the input.

The second overload only includes the numeric inputs. It calls the first overload with `$Strict` as `$true`. The second overload gives users a way to call the method without always having to define whether to strictly validate the input.

The class also defines `GetVolume()` as an instance (nonstatic) method. This method calls the second static overload, ensuring that the instance `GetVolume()` method always validates the cube's dimensions before returning the output value.

PowerShell

```powershell
class ExampleCube4 {
    [float]   $Height
    [float]   $Length
    [float]   $Width

    static [float] GetVolume(
        [float]$Height,
        [float]$Length,
        [float]$Width,
        [boolean]$Strict
    ) {
        $Signature = "[ExampleCube4]::GetVolume({0}, {1}, {2}, {3})"
        $Signature = $Signature -f $Height, $Length, $Width, $Strict
        Write-Verbose "Called $Signature"

        if ($Strict) {
            [ValidateScript({$_ -gt 0 })]$Height = $Height
            [ValidateScript({$_ -gt 0 })]$Length = $Length
            [ValidateScript({$_ -gt 0 })]$Width  = $Width
        }

        return $Height * $Length * $Width
    }

    static [float] GetVolume([float]$Height, [float]$Length, [float]$Width) {
        $Signature = "[ExampleCube4]::GetVolume($Height, $Length, $Width)"
        Write-Verbose "Called $Signature"

        return [ExampleCube4]::GetVolume($Height, $Length, $Width, $true)
    }

    [float] GetVolume() {
        Write-Verbose "Called `$this.GetVolume()"
        return [ExampleCube4]::GetVolume(
            $this.Height,
            $this.Length,
            $this.Width
        )
    }
}

$VerbosePreference = 'Continue'
$Cube = [ExampleCube4]@{ Height = 2 ; Length = 2 }
$Cube.GetVolume()
```

Output

```Output
VERBOSE: Called $this.GetVolume()
VERBOSE: Called [ExampleCube4]::GetVolume(2, 2, 0)
VERBOSE: Called [ExampleCube4]::GetVolume(2, 2, 0, True)

MetadataError:
Line |
  19 |              [ValidateScript({$_ -gt 0 })]$Width  = $Width
     |              ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     | The variable cannot be validated because the value 0 is not a valid
     | value for the Width variable.
```

The verbose messages in the method definitions show how the initial call to `$this.GetVolume()` calls the static method.

Calling the static method directly with the **Strict** parameter as `$false` returns `0` for the volume.

PowerShell

```powershell
[ExampleCube4]::GetVolume($Cube.Height, $Cube.Length, $Cube.Width, $false)
```

Output

```Output
VERBOSE: Called [ExampleCube4]::GetVolume(2, 2, 0, False)
0
```

Every class method has a unique signature that defines how to call the method. The method's output type, name, and parameters define the method signature.

When a class defines more than one method with the same name, the definitions of that method are *overloads*. Overloads for a method must have different parameters. A method can't define two implementations with the same parameters, even if the output types are different.

The following class defines two methods, `Shuffle()` and `Deal()`. The `Deal()` method defines two overloads, one without any parameters and the other with the **Count** parameter.

PowerShell

```powershell
class CardDeck {
    [string[]]$Cards  = @()
    hidden [string[]]$Dealt  = @()
    hidden [string[]]$Suits  = @('Clubs', 'Diamonds', 'Hearts', 'Spades')
    hidden [string[]]$Values = 2..10 + @('Jack', 'Queen', 'King', 'Ace')

    CardDeck() {
        foreach($Suit in $this.Suits) {
            foreach($Value in $this.Values) {
                $this.Cards += "$Value of $Suit"
            }
        }
        $this.Shuffle()
    }

    [void] Shuffle() {
        $this.Cards = $this.Cards + $this.Dealt | Where-Object -FilterScript {
             -not [string]::IsNullOrEmpty($_)
        } | Get-Random -Count $this.Cards.Count
    }

    [string] Deal() {
        if ($this.Cards.Count -eq 0) { throw "There are no cards left." }

        $Card        = $this.Cards[0]
        $this.Cards  = $this.Cards[1..$this.Cards.Count]
        $this.Dealt += $Card

        return $Card
    }

    [string[]] Deal([int]$Count) {
        if ($Count -gt $this.Cards.Count) {
            throw "There are only $($this.Cards.Count) cards left."
        } elseif ($Count -lt 1) {
            throw "You must deal at least 1 card."
        }

        return (1..$Count | ForEach-Object { $this.Deal() })
    }
}
```

By default, methods don't have any output. If a method signature includes an explicit output type other than **Void**, the method must return an object of that type. Methods don't emit any output except when the `return` keyword explicitly returns an object.

Class methods can define input parameters to use in the method body. Method parameters are enclosed in parentheses and are separated by commas. Empty parentheses indicate that the method requires no parameters.

Parameters can be defined on a single line or multiple lines. The following blocks show the syntax for method parameters.

Syntax

```Syntax
([[<parameter-type>]]$<parameter-name>[, [[<parameter-type>]]$<parameter-name>])
```

Syntax

```Syntax
(
    [[<parameter-type>]]$<parameter-name>[,
    [[<parameter-type>]]$<parameter-name>]
)
```

Method parameters can be strongly typed. If a parameter isn't typed, the method accepts any object for that parameter. If the parameter is typed, the method tries to convert the value for that parameter to the correct type, throwing an exception if the input can't be converted.

Method parameters can't define default values. All method parameters are mandatory.

Method parameters can't have any other attributes. This prevents methods from using parameters with the `Validate*` attributes. For more information about the validation attributes, see [about\_Functions\_Advanced\_Parameters](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_advanced_parameters?view=powershell-7.6#parameter-and-variable-validation-attributes).

You can use one of the following patterns to add validation to method parameters:

1.  Reassign the parameters to the same variables with the required validation attributes. This works for both static and instance methods. For an example of this pattern, see [Example 4](#example-4---static-method-with-overloads).
2.  Use `Update-TypeData` to define a `ScriptMethod` that uses validation attributes on the parameters directly. This only works for instance methods. For more information, see the [Defining instance methods with Update-TypeData](#define-instance-methods-with-update-typedata) section.

Not all automatic variables are available in methods. The following list includes automatic variables and suggestions for whether and how to use them in PowerShell class methods. Automatic variables not included in the list aren't available to class methods.

+   `$?` - Access as normal.
+   `$_` - Access as normal.
+   `$args` - Use the explicit parameter variables instead.
+   `$ConsoleFileName` - Access as `$Script:ConsoleFileName` instead.
+   `$Error` - Access as normal.
+   `$EnabledExperimentalFeatures` - Access as `$Script:EnabledExperimentalFeatures` instead.
+   `$Event` - Access as normal.
+   `$EventArgs` - Access as normal.
+   `$EventSubscriber` - Access as normal.
+   `$ExecutionContext` - Access as `$Script:ExecutionContext` instead.
+   `$false` - Access as normal.
+   `$foreach` - Access as normal.
+   `$HOME` - Access as `$Script:HOME` instead.
+   `$Host` - Access as `$Script:Host` instead.
+   `$input` - Use the explicit parameter variables instead.
+   `$IsCoreCLR` - Access as `$Script:IsCoreCLR` instead.
+   `$IsLinux` - Access as `$Script:IsLinux` instead.
+   `$IsMacOS` - Access as `$Script:IsMacOS` instead.
+   `$IsWindows` - Access as `$Script:IsWindows` instead.
+   `$LASTEXITCODE` - Access as normal.
+   `$Matches` - Access as normal.
+   `$MyInvocation` - Access as normal.
+   `$NestedPromptLevel` - Access as normal.
+   `$null` - Access as normal.
+   `$PID` - Access as `$Script:PID` instead.
+   `$PROFILE` - Access as `$Script:PROFILE` instead.
+   `$PSBoundParameters` - Don't use this variable. It's intended for cmdlets and functions. Using it in a class may have unexpected side effects.
+   `$PSCmdlet` - Don't use this variable. It's intended for cmdlets and functions. Using it in a class may have unexpected side effects.
+   `$PSCommandPath` - Access as normal.
+   `$PSCulture` - Access as `$Script:PSCulture` instead.
+   `$PSEdition` - Access as `$Script:PSEdition` instead.
+   `$PSHOME` - Access as `$Script:PSHOME` instead.
+   `$PSItem` - Access as normal.
+   `$PSScriptRoot` - Access as normal.
+   `$PSSenderInfo` - Access as `$Script:PSSenderInfo` instead.
+   `$PSUICulture` - Access as `$Script:PSUICulture` instead.
+   `$PSVersionTable` - Access as `$Script:PSVersionTable` instead.
+   `$PWD` - Access as normal.
+   `$Sender` - Access as normal.
+   `$ShellId` - Access as `$Script:ShellId` instead.
+   `$StackTrace` - Access as normal.
+   `$switch` - Access as normal.
+   `$this` - Access as normal. In a class method, `$this` is always the current instance of the class. You can access the class properties and methods with it. It's not available in static methods.
+   `$true` - Access as normal.

For more information about automatic variables, see [about\_Automatic\_Variables](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables?view=powershell-7.6).

You can hide methods of a class by declaring them with the `hidden` keyword. Hidden class methods are:

+   Not included in the list of class members returned by the `Get-Member` cmdlet. To show hidden methods with `Get-Member`, use the **Force** parameter.
+   Not displayed in tab completion or IntelliSense unless the completion occurs in the class that defines the hidden method.
+   Public members of the class. They can be called and inherited. Hiding a method doesn't make it private. It only hides the method as described in the previous points.

Note

When you hide any overload for a method, that method is removed from IntelliSense, completion results, and the default output for `Get-Member`.

For more information about the `hidden` keyword, see [about\_Hidden](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_hidden?view=powershell-7.6).

You can define a method as belonging to the class itself instead of instances of the class by declaring the method with the `static` keyword. Static class methods:

+   Are always available, independent of class instantiation.
+   Are shared across all instances of the class.
+   Are always available.
+   Can't access instance properties of the class. They can only access static properties.
+   Live for the entire session span.

When a class derives from a base class, it inherits the methods of the base class and their overloads. Any method overloads defined on the base class, including hidden methods, are available on the derived class.

A derived class can override an inherited method overload by redefining it in the class definition. To override the overload, the parameter types must be the same as for the base class. The output type for the overload can be different.

Unlike constructors, methods can't use the `: base(<parameters>)` syntax to invoke a base class overload for the method. The redefined overload on the derived class completely replaces the overload defined by the base class.

The following example shows the behavior for static and instance methods on derived classes.

The base class defines:

+   The static methods `Now()` for returning the current time and `DaysAgo()` for returning a date in the past.
+   The instance property **TimeStamp** and a `ToString()` instance method that returns the string representation of that property. This ensures that when an instance is used in a string it converts to the datetime string instead of the class name.
+   The instance method `SetTimeStamp()` with two overloads. When the method is called without parameters, it sets the **TimeStamp** to the current time. When the method is called with a **DateTime**, it sets the **TimeStamp** to that value.

PowerShell

```powershell
class BaseClass {
    static [datetime] Now() {
        return Get-Date
    }
    static [datetime] DaysAgo([int]$Count) {
        return [BaseClass]::Now().AddDays(-$Count)
    }

    [datetime] $TimeStamp = [BaseClass]::Now()

    [string] ToString() {
        return $this.TimeStamp.ToString()
    }

    [void] SetTimeStamp([datetime]$TimeStamp) {
        $this.TimeStamp = $TimeStamp
    }
    [void] SetTimeStamp() {
        $this.TimeStamp = [BaseClass]::Now()
    }
}
```

The next block defines classes derived from **BaseClass**:

+   **DerivedClassA** inherits from **BaseClass** without any overrides.
+   **DerivedClassB** overrides the `DaysAgo()` static method to return a string representation instead of the **DateTime** object. It also overrides the `ToString()` instance method to return the timestamp as an ISO8601 date string.
+   **DerivedClassC** overrides the parameterless overload of the `SetTimeStamp()` method so that setting the timestamp without parameters sets the date to 10 days before the current date.

PowerShell

```powershell
class DerivedClassA : BaseClass     {}
class DerivedClassB : BaseClass     {
    static [string] DaysAgo([int]$Count) {
        return [BaseClass]::DaysAgo($Count).ToString('yyyy-MM-dd')
    }
    [string] ToString() {
        return $this.TimeStamp.ToString('yyyy-MM-dd')
    }
}
class DerivedClassC : BaseClass {
    [void] SetTimeStamp() {
        $this.SetTimeStamp([BaseClass]::Now().AddDays(-10))
    }
}
```

The following block shows the output of the static `Now()` method for the defined classes. The output is the same for every class, because the derived classes don't override the base class implementation of the method.

PowerShell

```powershell
"[BaseClass]::Now()     => $([BaseClass]::Now())"
"[DerivedClassA]::Now() => $([DerivedClassA]::Now())"
"[DerivedClassB]::Now() => $([DerivedClassB]::Now())"
"[DerivedClassC]::Now() => $([DerivedClassC]::Now())"
```

Output

```Output
[BaseClass]::Now()     => 11/06/2023 09:41:23
[DerivedClassA]::Now() => 11/06/2023 09:41:23
[DerivedClassB]::Now() => 11/06/2023 09:41:23
[DerivedClassC]::Now() => 11/06/2023 09:41:23
```

The next block calls the `DaysAgo()` static method of each class. Only the output for **DerivedClassB** is different, because it overrode the base implementation.

PowerShell

```powershell
"[BaseClass]::DaysAgo(3)     => $([BaseClass]::DaysAgo(3))"
"[DerivedClassA]::DaysAgo(3) => $([DerivedClassA]::DaysAgo(3))"
"[DerivedClassB]::DaysAgo(3) => $([DerivedClassB]::DaysAgo(3))"
"[DerivedClassC]::DaysAgo(3) => $([DerivedClassC]::DaysAgo(3))"
```

Output

```Output
[BaseClass]::DaysAgo(3)     => 11/03/2023 09:41:38
[DerivedClassA]::DaysAgo(3) => 11/03/2023 09:41:38
[DerivedClassB]::DaysAgo(3) => 2023-11-03
[DerivedClassC]::DaysAgo(3) => 11/03/2023 09:41:38
```

The following block shows the string presentation of a new instance for each class. The representation for **DerivedClassB** is different because it overrode the `ToString()` instance method.

PowerShell

```powershell
"`$base = [BaseClass]::new()     => $($base = [BaseClass]::new(); $base)"
"`$a    = [DerivedClassA]::new() => $($a = [DerivedClassA]::new(); $a)"
"`$b    = [DerivedClassB]::new() => $($b = [DerivedClassB]::new(); $b)"
"`$c    = [DerivedClassC]::new() => $($c = [DerivedClassC]::new(); $c)"
```

Output

```Output
$base = [BaseClass]::new()     => 11/6/2023 9:44:57 AM
$a    = [DerivedClassA]::new() => 11/6/2023 9:44:57 AM
$b    = [DerivedClassB]::new() => 2023-11-06
$c    = [DerivedClassC]::new() => 11/6/2023 9:44:57 AM
```

The next block calls the `SetTimeStamp()` instance method for each instance, setting the **TimeStamp** property to a specific date. Each instance has the same date, because none of the derived classes override the parameterized overload for the method.

PowerShell

```powershell
[datetime]$Stamp = '2024-10-31'
"`$base.SetTimeStamp(`$Stamp) => $($base.SetTimeStamp($Stamp) ; $base)"
"`$a.SetTimeStamp(`$Stamp)    => $($a.SetTimeStamp($Stamp); $a)"
"`$b.SetTimeStamp(`$Stamp)    => $($b.SetTimeStamp($Stamp); $b)"
"`$c.SetTimeStamp(`$Stamp)    => $($c.SetTimeStamp($Stamp); $c)"
```

Output

```Output
$base.SetTimeStamp($Stamp) => 10/31/2024 12:00:00 AM
$a.SetTimeStamp($Stamp)    => 10/31/2024 12:00:00 AM
$b.SetTimeStamp($Stamp)    => 2024-10-31
$c.SetTimeStamp($Stamp)    => 10/31/2024 12:00:00 AM
```

The last block calls `SetTimeStamp()` without any parameters. The output shows that the value for the **DerivedClassC** instance is set to 10 days before the others.

PowerShell

```powershell
"`$base.SetTimeStamp() => $($base.SetTimeStamp() ; $base)"
"`$a.SetTimeStamp()    => $($a.SetTimeStamp(); $a)"
"`$b.SetTimeStamp()    => $($b.SetTimeStamp(); $b)"
"`$c.SetTimeStamp()    => $($c.SetTimeStamp(); $c)"
```

Output

```Output
$base.SetTimeStamp() => 11/6/2023 9:53:58 AM
$a.SetTimeStamp()    => 11/6/2023 9:53:58 AM
$b.SetTimeStamp()    => 2023-11-06
$c.SetTimeStamp()    => 10/27/2023 9:53:58 AM
```

Beyond declaring methods directly in the class definition, you can define methods for instances of a class in the static constructor using the `Update-TypeData` cmdlet.

Use this snippet as a starting point for the pattern. Replace the placeholder text in angle brackets as needed.

PowerShell

```powershell
class <ClassName> {
    static [hashtable[]] $MemberDefinitions = @(
        @{
            MemberName = '<MethodName>'
            MemberType = 'ScriptMethod'
            Value      = {
              param(<method-parameters>)

              <method-body>
            }
        }
    )

    static <ClassName>() {
        $TypeName = [<ClassName>].Name
        foreach ($Definition in [<ClassName>]::MemberDefinitions) {
            Update-TypeData -TypeName $TypeName @Definition
        }
    }
}
```

Tip

The `Add-Member` cmdlet can add properties and methods to a class in non-static constructors, but the cmdlet runs every time the constructor is called. Using `Update-TypeData` in the static constructor ensures that the code for adding the members to the class only needs to run once in a session.

Methods defined directly in a class declaration can't define default values or validation attributes on the method parameters. To define class methods with default values or validation attributes, they must be defined as **ScriptMethod** members.

In this example, the **CardDeck** class defines a `Draw()` method that uses both a validation attribute and a default value for the **Count** parameter.

PowerShell

```powershell
class CookieJar {
    [int] $Cookies = 12

    static [hashtable[]] $MemberDefinitions = @(
        @{
            MemberName = 'Eat'
            MemberType = 'ScriptMethod'
            Value      = {
                param(
                    [ValidateScript({ $_ -ge 1 -and $_ -le $this.Cookies })]
                    [int] $Count = 1
                )

                $this.Cookies -= $Count
                if ($Count -eq 1) {
                    "You ate 1 cookie. There are $($this.Cookies) left."
                } else {
                    "You ate $Count cookies. There are $($this.Cookies) left."
                }
            }
        }
    )

    static CookieJar() {
        $TypeName = [CookieJar].Name
        foreach ($Definition in [CookieJar]::MemberDefinitions) {
            Update-TypeData -TypeName $TypeName @Definition
        }
    }
}

$Jar = [CookieJar]::new()
$Jar.Eat(1)
$Jar.Eat()
$Jar.Eat(20)
$Jar.Eat(6)
```

Output

```Output
You ate 1 cookie. There are 11 left.

You ate 1 cookie. There are 10 left.

MethodInvocationException:
Line |
  36 |  $Jar.Eat(20)
     |  ~~~~~~~~~~~~
     | Exception calling "Eat" with "1" argument(s): "The attribute
     | cannot be added because variable Count with value 20 would no
     | longer be valid."

You ate 6 cookies. There are 4 left.
```

Note

While this pattern works for validation attributes, notice that the exception is misleading, referencing an inability to add an attribute. It might be a better user experience to explicitly check the value for the parameter and raise a meaningful error instead. That way, users can understand why they're seeing the error and what to do about it.

PowerShell class methods have the following limitations:

+   Method parameters can't use any attributes, including validation attributes.

    Workaround: Reassign the parameters in the method body with the validation attribute or define the method in the static constructor with the `Update-TypeData` cmdlet.

+   Method parameters can't define default values. The parameters are always mandatory.

    Workaround: Define the method in the static constructor with the `Update-TypeData` cmdlet.

+   Methods are always public, even when they're hidden. They can be overridden when the class is inherited.

    Workaround: None.

+   If any overload of a method is hidden, every overload for that method is treated as hidden too.

    Workaround: None.

---

## PsCraft Examples

The following examples are extracted directly from the PsCraft implementation under `Private/`. They show how the project uses method declarations, static factories, and instance methods in a real, non-trivial build system.

### Example 1 — `AliasVisitor`: AST-visitor overrides that return `[AstVisitAction]`

[AliasVisitor](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L11-L121) is a class that walks a PowerShell AST and pulls out every `New-Alias` / `Set-Alias` / `Remove-Alias` directive. It overrides four methods of the inherited `System.Management.Automation.Language.AstVisitor`. Every override returns one of `[AstVisitAction]::Continue`, `::SkipChildren`, or `::StopVisit`.

```powershell
class AliasVisitor : System.Management.Automation.Language.AstVisitor {
  [string]$Parameter = $null
  [string]$Command = $null
  [string]$Name = $null
  [string]$Value = $null
  [string]$Scope = $null
  [System.Collections.Generic.HashSet[string]]$Aliases = @()

  # Captures -Name, -Value, -Scope, -Force, etc.
  [AstVisitAction] VisitCommandParameter([CommandParameterAst]$ast) {
    $this.Parameter = $ast.ParameterName
    return [AstVisitAction]::Continue
  }

  # Captures the literal string of every parameter value (and the command name on the first hit)
  [AstVisitAction] VisitStringConstantExpression([StringConstantExpressionAst]$ast) {
    if (!$this.Command) {
      $this.Command = $ast.Value
      return [AstVisitAction]::Continue
    }
    switch -Wildcard ($this.Parameter) {
      'S*'  { $this.Scope = $ast.Value }
      'N*'  { $this.Name  = $ast.Value }
      'Va*' { $this.Value = $ast.Value }
      default {
        if (!$this.Parameter) {
          if (!$this.Name) { $this.Name = $ast.Value } else { $this.Value = $ast.Value }
        }
      }
    }
    $this.Parameter = $null
    if ($this.Name -and $this.Command -eq 'Remove-Alias') {
      $this.Command = 'Remove-Alias'
      return [AstVisitAction]::StopVisit
    } elseif ($this.Name -and $this.Scope -eq 'Global') {
      return [AstVisitAction]::StopVisit
    }
    return [AstVisitAction]::Continue
  }

  # The [Alias(...)] attribute on functions matters, but aliases inside a function don't
  [AstVisitAction] VisitFunctionDefinition([FunctionDefinitionAst]$ast) {
    @($ast.Body.ParamBlock.Attributes.Where{ $_.TypeName.Name -eq 'Alias' }.PositionalArguments.Value).ForEach{
      if ($_) { $this.Aliases.Add($_) }
    }
    return [AstVisitAction]::SkipChildren
  }

  # Top-level commands matter, but only if they're alias commands
  [AstVisitAction] VisitCommand([CommandAst]$ast) {
    if ($ast.CommandElements[0].Value -imatch '(New|Set|Remove)-Alias') {
      $ast.Visit($this.ClearParameters())
      $Params = $this.GetParameters()
      if ($Params.Command -ieq 'Remove-Alias') {
        if ($this.Aliases.Contains($Params.Name)) {
          Write-Verbose -Message "Alias '$($Params.Name)' is removed by line $($ast.Extent.StartLineNumber): $($ast.Extent.Text)"
          $this.Aliases.Remove($Params.Name)
        }
      } elseif ($Params.Name -and $Params.Scope -ine 'Global') {
        $this.Aliases.Add($this.Parameters.Name)
      }
    }
    return [AstVisitAction]::SkipChildren
  }
}
```

The `Continue` / `SkipChildren` / `StopVisit` pattern is the single most important convention to know when overriding any `AstVisitor`-derived class. Use `Continue` to keep walking the AST, `SkipChildren` to not recurse into a sub-tree you have already handled, and `StopVisit` to abort the entire walk.

---

### Example 2 — Static factory methods on `PsModule`

[PsModule](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L305-L316) exposes four `static [PsModule] Create(...)` overloads that act as named constructors. They are preferred over the bare `::new()` form because they always return a fully-initialized object with files and folders populated.

```powershell
class PsModule : IDisposable {
  # ...constructors and properties...

  static [PsModule] Create([string]$Name) {
    return [PsModule]::new($Name, [System.Management.Automation.ModuleType]::Script)
  }
  static [PsModule] Create([string]$Name, [System.Management.Automation.ModuleType]$Type) {
    return [PsModule]::new($Name, $Type)
  }
  static [PsModule] Create([string]$Name, [string]$Path) {
    return [PsModule]::new($Name, [IO.DirectoryInfo]::new($Path),
      [System.Management.Automation.ModuleType]::Script)
  }
  static [PsModule] Create([string]$Name, [string]$Path, [System.Management.Automation.ModuleType]$Type) {
    $b = [PsModuleBase]::GetunResolvedPath($Path)
    $p = [IO.Path]::Combine($b, $Name)
    $d = [IO.DirectoryInfo]::new($p)
    if (![IO.Directory]::Exists($d)) {
      return [PsModule]::new($d.BaseName, $d.Parent, $Type)
    }
    [BuildLog]::Write("Directory $d already exists, Loading module from $p`n")
    return [PsModule]::Load($d)
  }

  static [PsModule] Load([IO.DirectoryInfo]$Path) { # ...reads an existing .psd1 from disk }
  static [PsModule] Load([string]$Path)            { return [PsModule]::Load([IO.DirectoryInfo]::new([PsModuleBase]::GetResolvedPath($Path))) }
  static [PsModule] Load([string]$Name, [string]$Path) { return [PsModule]::Load([IO.DirectoryInfo]::new([PsModuleBase]::GetResolvedPath([IO.Path]::Combine($Path, $Name)))) }
}
```

Static factory methods are the idiomatic place to:

- run environment-dependent logic (path resolution, disk existence checks),
- call the constructors with fully-resolved arguments,
- choose between `Create` (always a fresh in-memory module) and `Load` (read an existing module from disk).

---

### Example 3 — `static [PsCraft] From([string]$RootPath, [ref]$o)`: a factory with a `[ref]` parameter

[PsCraft::From](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L775-L805) is the workhorse used by every public cmdlet. It builds a fully-wired `PsCraft` instance and, **if a `[ref]` is supplied, copies its public properties onto the existing object** passed in. This is the in-place form of the factory pattern.

```powershell
static [PsCraft] From([string]$RootPath, [ref]$o) {
  $b = [PsCraft]::new();
  [Net.ServicePointManager]::SecurityProtocol = [PsCraft]::GetSecurityProtocol();

  # Initialize the build context instead of scattering environment variables
  $projName = [IO.DirectoryInfo]::new($RootPath).BaseName
  $b.BuildContext = [BuildContext]::new($projName, $RootPath, '0.0.0')
  $b.UseVerbose = $Script:VerbosePreference -eq 'Continue'

  $_RootPath = [PsModuleBase]::GetunresolvedPath($RootPath);
  if ([IO.Directory]::Exists($_RootPath)) {
    $b.RootPath = $_RootPath
  } else {
    throw [DirectoryNotFoundException]::new("RootPath $RootPath Not Found")
  }
  $b.ModuleName = [IO.DirectoryInfo]::new($_RootPath).BaseName;
  $b.BuildOutputPath = [System.IO.Path]::Combine($_RootPath, 'BuildOutput');
  $b.TestsPath = [System.IO.Path]::Combine($b.RootPath, 'Tests');
  $b.dataFile = [System.IO.FileInfo]::new(
    [System.IO.Path]::Combine($b.RootPath, 'en-US', "$($b.RootPath.BaseName).strings.psd1")
  )
  $b.buildFile = New-Item $([System.IO.Path]::GetTempFileName().Replace('.tmp', '.ps1'));
  if (!$b.dataFile.Exists) {
    throw [System.IO.FileNotFoundException]::new(
      'Unable to find the LocalizedData file.', "$($b.dataFile.BaseName).strings.psd1"
    )
  }
  $b.LocalizedData = Read-ModuleData -File $b.dataFile

  # If the caller passed a [ref]$o, copy our properties back onto their object
  if ($null -ne $o) {
    $o.value.GetType().GetProperties().ForEach({
        $v = $b.$($_.Name)
        if ($null -ne $v) { $o.value.$($_.Name) = $v }
      })
    return $o.Value
  }
  return $b
}
```

Usage:

```powershell
# Return a brand-new instance
$craft = [PsCraft]::From('C:/src/MyModule', $null)

# Re-use an existing instance (e.g. one already stored in a class field)
[void][PsCraft]::From('C:/src/MyModule', [ref]$this)   # populate $this in-place
```

The `[ref]` is a one-element reference to a variable; PowerShell's `[ref]` cast unwraps the `.Value` and `[ref]$o` returns the inner object. This is a common pattern in PowerShell classes that want to support both "create new" and "fill in" forms of a factory.

---

### Example 4 — `BuildOrchestrator.Compile()`: switch-based dispatch on a property

[BuildOrchestrator::Compile](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L962-L978) shows the standard PsCraft "switch on the type" pattern. The class property `$this.ModuleType` is one of `Script` / `Binary` / `Cim` / `Manifest`; `Compile()` dispatches to a different method for each.

```powershell
[bool] Compile() {
  [BuildLog]::WriteHeading("Compiling module type: $($this.ModuleType)")
  [BuildLog]::WriteStep("Formatting module code...")
  $mod = [PsModule]::Load($this.Path)
  $mod.FormatCode()
  $success = switch ($this.ModuleType) {
    'Script'   { $this.CompileScriptModule()   }
    'Binary'   { $this.CompileBinaryModule()   }
    'Cim'      { $this.CompileCimModule()      }
    'Manifest' { $this.CompileManifestModule() }
    default {
      [BuildLog]::WriteSevere("Unknown ModuleType: $($this.ModuleType)")
      $false
    }
  }
  return $success
}
```

Each branch returns a `[bool]` (success/failure) so the caller can react. The default branch is always last and emits a `WriteSevere` so a misconfigured project never silently passes.

---

### Example 5 — `BuildOrchestrator.Run([string[]]$tasks)`: progress display with `[AnsiConsole]`

[BuildOrchestrator::Run](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L1427-L1467) is the orchestrator entry point invoked by `Build-Module`. It demonstrates a common PsCraft pattern: try the rich UI (`[AnsiConsole]` from cliHelper), catch the missing-type exception, and fall back to plain `[BuildLog]` output.

```powershell
[int] Run([string[]]$tasks) {
  $psd1Path = [IO.Path]::Combine(
    $this.Path, "$([IO.DirectoryInfo]::new($this.Path).BaseName).psd1"
  )
  $buildNumber = '0.0.0'
  if ([IO.File]::Exists($psd1Path)) {
    try {
      $manifest = Import-PowerShellDataFile -Path $psd1Path -ErrorAction Ignore
      if ($manifest.ModuleVersion) { $buildNumber = $manifest.ModuleVersion }
    } catch {
      $null = $this.Cmdlet.WriteWarning(
        "Failed to read module version from manifest: $_. Using default 0.0.0"
      )
    }
  }
  $this.InitializeBuildContext([version]$buildNumber)

  if (Get-Command 'Set-BuildVariables' -ErrorAction Ignore) {
    Set-BuildVariables $this.Path $this.Context.RunId
  }

  try {
    [AnsiConsole]::Progress().Start([Action[object]] {
        param($ctx)
        $cleanTask   = $ctx.AddTask('[cyan]Clean[/]',   $true, 100)
        $compileTask = $ctx.AddTask('[cyan]Compile[/]', $true, 100)
        $testTask    = $ctx.AddTask('[cyan]Test[/]',    $true, 100)
        if ('Clean'   -in $tasks) { $this.Clean();   $cleanTask.Value   = 100 }
        if ('Compile' -in $tasks) { $this.Compile(); $compileTask.Value = 100 }
        if ('Test'    -in $tasks) { $this.Test();    $testTask.Value    = 100 }
      })
  } catch {
    # Fallback: plain sequential execution with BuildLog step headers
    if ('Clean'   -in $tasks) { [BuildLog]::WriteHeading('Clean');   $this.Clean()   }
    if ('Compile' -in $tasks) { [BuildLog]::WriteHeading('Compile'); $this.Compile() }
    if ('Test'    -in $tasks) { [BuildLog]::WriteHeading('Test');    $this.Test()    }
  }
  return 0
}
```

Two patterns worth noting:

1. The `$this.Cmdlet` instance is used to call `WriteWarning` instead of `Write-Warning`, so the message is bound to the calling cmdlet and respects its `-WarningAction` preference.
2. The `try { [AnsiConsole]::Progress().Start(...) } catch { [BuildLog]::WriteHeading(...) }` block lets the build stay usable in environments where `Spectre.Console` (cliHelper) is not loaded — the bare-class `[BuildLog]` is always present.

---

### Example 6 — `BuildOrchestrator.Clean()` and `BuildOrchestrator.Test()`: minimal-instance-method shape

[BuildOrchestrator::Clean](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L1469-L1474) and [`Test`](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L1476-L1478) are short instance methods that just call into the project state — no input parameters, no overloads, no complex logic.

```powershell
[void] Clean() {
  $versionDir = $this.Context.GetVersionedOutputPath()
  if (Test-Path $versionDir -ea Ignore) {
    Remove-Item $versionDir -Recurse -Force -ea Ignore
  }
}

[void] Test() {
  # To be implemented in Phase 5
}
```

A `[void]` return type makes the intent explicit ("this method is a side-effect; its return value is not interesting"). Because `Test` has no parameters, it can be invoked like `BuildOrchestrator::Test()` from anywhere, and the return value (if it had one) cannot be captured by accident.

---

### Example 7 — `static [void]` class: `BuildLog` is essentially a static service

[BuildLog](file:///d:/GitHub/PsCraft/Private/BuildLog.psm1#L85-L290) is a class whose every member is `static`. It replaces six loose `.ps1` helper functions (`Get-Elapsed`, `Write-BuildLog`, `Write-Heading`, …) with a single named type whose every method has a verb-noun style name.

```powershell
class BuildLog {
  static [string] GetElapsed() { ... }
  static [void] Write([object]$Message)                   { [BuildLog]::_Write($Message, $false, $false, $false, $false) }
  static [void] WriteCmd([object]$Message)               { [BuildLog]::_Write($Message, $true,  $false, $false, $false) }
  static [void] WriteWarning([object]$Message)           { [BuildLog]::_Write($Message, $false, $true,  $false, $false) }
  static [void] WriteSevere([object]$Message)            { [BuildLog]::_Write($Message, $false, $false, $true,  $false) }
  static [void] WriteClean([object]$Message)             { [BuildLog]::_Write($Message, $false, $false, $false, $true ) }
  static [void] WriteStatus([string]$Message, [string]$Level = 'info') { ... }
  static [void] WriteStep([string]$Message)              { [BuildLog]::WriteStatus("[bold]•[/] $Message", 'info') }
  static [void] WriteHeading([string]$Title)             { [void][BuildLog]::WriteHeading($Title, $false) }
  static [string] WriteHeading([string]$Title, [bool]$Passthru) { ... }
  static [void] WriteBanner([string]$Title = 'PsCraft')  { ... }
  static [void] WriteEnvironmentSummary([string]$State)  { ... }
  static [void] WriteTerminatingError(...)               { ... }
  static [object[]] InvokeCommandWithLog([scriptblock]$ScriptBlock) { ... }

  # private implementation shared by every Write* method
  static hidden [void] _Write([object]$Message, [bool]$Cmd, [bool]$Warning, [bool]$Severe, [bool]$Clean) { ... }
}
```

Pattern takeaways:

- A class with **only** `static` members is a great way to group related utilities under a single namespace without forcing callers to instantiate anything.
- Public thin methods (`Write`, `WriteCmd`, `WriteWarning`, …) share one private implementation (`hidden _Write`) parameterized by booleans — the same shape you'd use for a switch statement in C#.
- The `WriteStatus` method's second parameter `[string]$Level = 'info'` is a default value at the **method parameter** level — allowed because it is a method parameter, not a constructor parameter.

---

### Example 8 — Instance method: `BuildSummary.AddTask` and `RenderSummary`

[BuildSummary](file:///d:/GitHub/PsCraft/Private/BuildLog.psm1#L292-L405) ties together `BuildTaskResult` and `TestResult` to render a panel with all build outcomes.

```powershell
[void] AddTask([string]$Name, [bool]$Success, [timespan]$Duration) {
  $task = [BuildTaskResult]::new($Name, $Success, $Duration)
  $this.Tasks.Add($task)
  if (!$Success) { $this.Success = $false }
}

[void] SetTestResults([int]$Total, [int]$Passed, [int]$Failed, [int]$Skipped) {
  $this.TestResults = [TestResult]::new($Total, $Passed, $Failed, $Skipped)
  if ($Failed -gt 0) { $this.Success = $false }
}

[void] RenderSummary() {
  $this.EndTime = [datetime]::Now
  $totalDuration = $this.TotalDuration
  try {
    $table = [Table]::new()
    [void]$table.AddColumn([TableColumn]::new('Task'))
    [void]$table.AddColumn([TableColumn]::new('Status'))
    [void]$table.AddColumn([TableColumn]::new('Duration'))
    foreach ($task in $this.Tasks) {
      $status = if ($task.Success) { '[green]✓ Pass[/]' } else { '[red]✗ Fail[/]' }
      $duration = $task.Duration.ToString('mm\:ss')
      [void]$table.AddRow(@($task.Name, $status, $duration))
    }
    # ...build the panel and write it via [AnsiConsole]
  } catch {
    # Fallback: plain BuildLog
  }
}
```

`AddTask` and `SetTestResults` are simple mutators that also flip the `$Success` flag — a common pattern in result-aggregator classes.

---

### Example 9 — Operator-like methods: `PsModule.Equals`, `GetHashCode`, `ToString`

[PsModule](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L576-L593) overrides the standard trio. Note the **critical detail** in `Equals`: the parameter must be `[object]`, not `[PsModule]`. Earlier revisions used `[PsModule]$other` and broke with a `Type must be a type provided by the runtime` error. The current code uses `-as [PsModule]` for a safe cast.

```powershell
[bool] Equals([object]$other) {
  if ($null -eq $other) { return $false }
  if ([object]::ReferenceEquals($this, $other)) { return $true }
  $o = $other -as [PsModule]
  if ($null -eq $o) { return $false }
  return ($this.Name -eq $o.Name) -and ($this.Path.FullName -eq $o.Path.FullName)
}

[int] GetHashCode() {
  $hash = 17
  if ($null -ne $this.Name) { $hash = $hash * 23 + $this.Name.GetHashCode() }
  if ($null -ne $this.Path) { $hash = $hash * 23 + $this.Path.FullName.GetHashCode() }
  return $hash
}

[string] ToString() {
  return "$($this.Name) @ $($this.Path.FullName)"
}
```

If you override `Equals` in a PowerShell class:

- Always accept `[object]`, never the derived type.
- Use the `-as` operator (or ` -is` + cast) to safely narrow to your own type.
- Override `GetHashCode` to be consistent with `Equals` (same fields, same combination).
- Override `ToString` for friendlier logging and CLI output.

---

### Related

- See [about_Classes_Constructors](about_Classes_Constructors.md) for the constructor patterns that pair with these methods (e.g. the `Init()`-chained constructors that the factory methods call).
- See [about_Classes_Properties](about_Classes_Properties.md) for the `static [hashtable[]] $MemberDefinitions` + `static BuildContext()` / `static BuildSummary()` pattern used to register `ScriptProperty` definitions whose bodies are themselves methods.
- See [about_Classes_Inheritance](about_Classes_Inheritance.md) for the base classes (`AstVisitor`, `ModuleCmdletBase`, `PsCraft`, `Dictionary[string, Object]`) these methods override.
