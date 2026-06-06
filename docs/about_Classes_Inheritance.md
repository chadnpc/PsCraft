# Describes how you can define classes that extend other types.

PowerShell classes support *inheritance*, which allows you to define a child class that reuses (inherits), extends, or modifies the behavior of a parent class. The class whose members are inherited is called the *base class*. The class that inherits the members of the base class is called the *derived class*.

PowerShell supports single inheritance only. A class can only inherit from a single class. However, inheritance is transitive, which allows you to define an inheritance hierarchy for a set of types. In other words, type **D** can inherit from type **C**, which inherits from type **B**, which inherits from the base class type **A**. Because inheritance is transitive, the members of type **A** are available to type **D**.

Derived classes don't inherit all members of the base class. The following members aren't inherited:

+   Static constructors, which initialize the static data of a class.
+   Instance constructors, which you call to create a new instance of the class. Each class must define its own constructors.

You can extend a class by creating a new class that derives from an existing class. The derived class inherits the properties and methods of the base class. You can add or override the base class members as required.

Classes can also inherit from interfaces, which define a contract. A class that inherits from an interface must implement that contract. When it does, the class is usable like any other class implementing that interface. If a class inherits from an interface but doesn't implement the interface, PowerShell raises a parsing error for the class.

Some PowerShell operators depend on a class implementing a specific interface. For example, the `-eq` operator only checks for reference equality unless the class implements the **System.IEquatable** interface. The `-le`, `-lt`, `-ge`, and `-gt` operators only work on classes that implement the **System.IComparable** interface.

A derived class uses the `:` syntax to extend a base class or implement interfaces. The derived class should always be leftmost in the class declaration.

This example shows the basic PowerShell class inheritance syntax.

PowerShell

```powershell
class Derived : Base {...}
```

This example shows inheritance with an interface declaration coming after the base class.

PowerShell

```powershell
class Derived : Base, Interface {...}
```

Class inheritance uses the following syntaxes:

Syntax

```Syntax
class <derived-class-name> : <base-class-or-interface-name>[, <interface-name>...] {
    <derived-class-body>
}
```

For example:

PowerShell

```powershell
# Base class only
class Derived : Base {...}
# Interface only
class Derived : System.IComparable {...}
# Base class and interface
class Derived : Base, System.IComparable {...}
```

Syntax

```Syntax
class <derived-class-name> : <base-class-or-interface-name>[,
    <interface-name>...] {
    <derived-class-body>
}
```

For example:

PowerShell

```powershell
class Derived : Base,
                System.IComparable,
                System.IFormattable,
                System.IConvertible {
    # Derived class definition
}
```

The following example shows the behavior of inherited properties with and without overriding. Run the code blocks in order after reading their description.

The first code block defines **PublishedWork** as a base class. It has two static properties, **List** and **Artists**. Next, it defines the static `RegisterWork()` method to add works to the static **List** property and the artists to the **Artists** property, writing a message for each new entry in the lists.

The class defines three instance properties that describe a published work. Finally, it defines the `Register()` and `ToString()` instance methods.

PowerShell

```powershell
class PublishedWork {
    static [PublishedWork[]] $List    = @()
    static [string[]]        $Artists = @()

    static [void] RegisterWork([PublishedWork]$Work) {
        $wName   = $Work.Name
        $wArtist = $Work.Artist
        if ($Work -notin [PublishedWork]::List) {
            Write-Verbose "Adding work '$wName' to works list"
            [PublishedWork]::List += $Work
        } else {
            Write-Verbose "Work '$wName' already registered."
        }
        if ($wArtist -notin [PublishedWork]::Artists) {
            Write-Verbose "Adding artist '$wArtist' to artists list"
            [PublishedWork]::Artists += $wArtist
        } else {
            Write-Verbose "Artist '$wArtist' already registered."
        }
    }

    static [void] ClearRegistry() {
        Write-Verbose "Clearing PublishedWork registry"
        [PublishedWork]::List    = @()
        [PublishedWork]::Artists = @()
    }

    [string] $Name
    [string] $Artist
    [string] $Category

    [void] Init([string]$WorkType) {
        if ([string]::IsNullOrEmpty($this.Category)) {
            $this.Category = "${WorkType}s"
        }
    }

    PublishedWork() {
        $WorkType = $this.GetType().FullName
        $this.Init($WorkType)
        Write-Verbose "Defined a published work of type [$WorkType]"
    }

    PublishedWork([string]$Name, [string]$Artist) {
        $WorkType    = $this.GetType().FullName
        $this.Name   = $Name
        $this.Artist = $Artist
        $this.Init($WorkType)

        Write-Verbose "Defined '$Name' by $Artist as a published work of type [$WorkType]"
    }

    PublishedWork([string]$Name, [string]$Artist, [string]$Category) {
        $WorkType    = $this.GetType().FullName
        $this.Name   = $Name
        $this.Artist = $Artist
        $this.Init($WorkType)

        Write-Verbose "Defined '$Name' by $Artist ($Category) as a published work of type [$WorkType]"
    }

    [void]   Register() { [PublishedWork]::RegisterWork($this) }
    [string] ToString() { return "$($this.Name) by $($this.Artist)" }
}
```

The first derived class is **Album**. It doesn't override any properties or methods. It adds a new instance property, **Genres**, that doesn't exist on the base class.

PowerShell

```powershell
class Album : PublishedWork {
    [string[]] $Genres   = @()
}
```

The following code block shows the behavior of the derived **Album** class. First, it sets the `$VerbosePreference` so that the messages from the class methods emit to the console. It creates three instances of the class, shows them in a table, and then registers them with the inherited static `RegisterWork()` method. It then calls the same static method on the base class directly.

PowerShell

```powershell
$VerbosePreference = 'Continue'
$Albums = @(
    [Album]@{
        Name   = 'The Dark Side of the Moon'
        Artist = 'Pink Floyd'
        Genres = 'Progressive rock', 'Psychedelic rock'
    }
    [Album]@{
        Name   = 'The Wall'
        Artist = 'Pink Floyd'
        Genres = 'Progressive rock', 'Art rock'
    }
    [Album]@{
        Name   = '36 Chambers'
        Artist = 'Wu-Tang Clan'
        Genres = 'Hip hop'
    }
)

$Albums | Format-Table
$Albums | ForEach-Object { [Album]::RegisterWork($_) }
$Albums | ForEach-Object { [PublishedWork]::RegisterWork($_) }
```

Output

```Output
VERBOSE: Defined a published work of type [Album]
VERBOSE: Defined a published work of type [Album]
VERBOSE: Defined a published work of type [Album]

Genres                               Name                      Artist       Category
------                               ----                      ------       --------
{Progressive rock, Psychedelic rock} The Dark Side of the Moon Pink Floyd   Albums
{Progressive rock, Art rock}         The Wall                  Pink Floyd   Albums
{Hip hop}                            36 Chambers               Wu-Tang Clan Albums

VERBOSE: Adding work 'The Dark Side of the Moon' to works list
VERBOSE: Adding artist 'Pink Floyd' to artists list
VERBOSE: Adding work 'The Wall' to works list
VERBOSE: Artist 'Pink Floyd' already registered.
VERBOSE: Adding work '36 Chambers' to works list
VERBOSE: Adding artist 'Wu-Tang Clan' to artists list

VERBOSE: Work 'The Dark Side of the Moon' already registered.
VERBOSE: Artist 'Pink Floyd' already registered.
VERBOSE: Work 'The Wall' already registered.
VERBOSE: Artist 'Pink Floyd' already registered.
VERBOSE: Work '36 Chambers' already registered.
VERBOSE: Artist 'Wu-Tang Clan' already registered.
```

Notice that even though the **Album** class didn't define a value for **Category** or any constructors, the property was defined by the default constructor of the base class.

In the verbose messaging, the second call to the `RegisterWork()` method reports that the works and artists are already registered. Even though the first call to `RegisterWork()` was for the derived **Album** class, it used the inherited static method from the base **PublishedWork** class. That method updated the static **List** and **Artist** properties on the base class, which the derived class didn't override.

The next code block clears the registry and calls the `Register()` instance method on the **Album** objects.

PowerShell

```powershell
[PublishedWork]::ClearRegistry()
$Albums.Register()
```

Output

```Output
VERBOSE: Clearing PublishedWork registry

VERBOSE: Adding work 'The Dark Side of the Moon' to works list
VERBOSE: Adding artist 'Pink Floyd' to artists list
VERBOSE: Adding work 'The Wall' to works list
VERBOSE: Artist 'Pink Floyd' already registered.
VERBOSE: Adding work '36 Chambers' to works list
VERBOSE: Adding artist 'Wu-Tang Clan' to artists list
```

The instance method on the **Album** objects has the same effect as calling the static method on the derived or base class.

The following code block compares the static properties for the base class and the derived class, showing that they're the same.

PowerShell

```powershell
[pscustomobject]@{
    '[PublishedWork]::List'    = [PublishedWork]::List -join ",`n"
    '[Album]::List'            = [Album]::List -join ",`n"
    '[PublishedWork]::Artists' = [PublishedWork]::Artists -join ",`n"
    '[Album]::Artists'         = [Album]::Artists -join ",`n"
    'IsSame::List'             = (
        [PublishedWork]::List.Count -eq [Album]::List.Count -and
        [PublishedWork]::List.ToString() -eq [Album]::List.ToString()
    )
    'IsSame::Artists'          = (
        [PublishedWork]::Artists.Count -eq [Album]::Artists.Count -and
        [PublishedWork]::Artists.ToString() -eq [Album]::Artists.ToString()
    )
} | Format-List
```

Output

```Output
[PublishedWork]::List    : The Dark Side of the Moon by Pink Floyd,
                           The Wall by Pink Floyd,
                           36 Chambers by Wu-Tang Clan
[Album]::List            : The Dark Side of the Moon by Pink Floyd,
                           The Wall by Pink Floyd,
                           36 Chambers by Wu-Tang Clan
[PublishedWork]::Artists : Pink Floyd,
                           Wu-Tang Clan
[Album]::Artists         : Pink Floyd,
                           Wu-Tang Clan
IsSame::List             : True
IsSame::Artists          : True
```

The next code block defines the **Illustration** class inheriting from the base **PublishedWork** class. The new class extends the base class by defining the **Medium** instance property with a default value of `Unknown`.

Unlike the derived **Album** class, **Illustration** overrides the following properties and methods:

+   It overrides the static **Artists** property. The definition is the same, but the **Illustration** class declares it directly.
+   It overrides the **Category** instance property, setting the default value to `Illustrations`.
+   It overrides the `ToString()` instance method so the string representation of an illustration includes the medium it was created with.

The class also defines the static `RegisterIllustration()` method to first call the base class `RegisterWork()` method and then add the artist to the overridden **Artists** static property on the derived class.

Finally, the class overrides all three constructors:

1.  The default constructor is empty except for a verbose message indicating it created an illustration.
2.  The next constructor takes two string values for the name and artist that created the illustration. Instead of implementing the logic for setting the **Name** and **Artist** properties, the constructor calls the appropriate constructor from the base class.
3.  The last constructor takes three string values for the name, artist, and medium of the illustration. Both constructors write a verbose message indicating that they created an illustration.

PowerShell

```powershell
class Illustration : PublishedWork {
    static [string[]] $Artists = @()

    static [void] RegisterIllustration([Illustration]$Work) {
        $wArtist = $Work.Artist

        [PublishedWork]::RegisterWork($Work)

        if ($wArtist -notin [Illustration]::Artists) {
            Write-Verbose "Adding illustrator '$wArtist' to artists list"
            [Illustration]::Artists += $wArtist
        } else {
            Write-Verbose "Illustrator '$wArtist' already registered."
        }
    }

    [string] $Category = 'Illustrations'
    [string] $Medium   = 'Unknown'

    [string] ToString() {
        return "$($this.Name) by $($this.Artist) ($($this.Medium))"
    }

    Illustration() {
        Write-Verbose 'Defined an illustration'
    }

    Illustration([string]$Name, [string]$Artist) : base($Name, $Artist) {
        Write-Verbose "Defined '$Name' by $Artist ($($this.Medium)) as an illustration"
    }

    Illustration([string]$Name, [string]$Artist, [string]$Medium) {
        $this.Name = $Name
        $this.Artist = $Artist
        $this.Medium = $Medium

        Write-Verbose "Defined '$Name' by $Artist ($Medium) as an illustration"
    }
}
```

The following code block shows the behavior of the derived **Illustration** class. It creates three instances of the class, shows them in a table, and then registers them with the inherited static `RegisterWork()` method. It then calls the same static method on the base class directly. Finally, it writes messages showing the list of registered artists for the base class and the derived class.

PowerShell

```powershell
$Illustrations = @(
    [Illustration]@{
        Name   = 'The Funny Thing'
        Artist = 'Wanda Gág'
        Medium = 'Lithography'
    }
    [Illustration]::new('Millions of Cats', 'Wanda Gág')
    [Illustration]::new(
      'The Lion and the Mouse',
      'Jerry Pinkney',
      'Watercolor'
    )
)

$Illustrations | Format-Table
$Illustrations | ForEach-Object { [Illustration]::RegisterIllustration($_) }
$Illustrations | ForEach-Object { [PublishedWork]::RegisterWork($_) }
"Published work artists: $([PublishedWork]::Artists -join ', ')"
"Illustration artists: $([Illustration]::Artists -join ', ')"
```

Output

```Output
VERBOSE: Defined a published work of type [Illustration]
VERBOSE: Defined an illustration
VERBOSE: Defined 'Millions of Cats' by Wanda Gág as a published work of type [Illustration]
VERBOSE: Defined 'Millions of Cats' by Wanda Gág (Unknown) as an illustration
VERBOSE: Defined a published work of type [Illustration]
VERBOSE: Defined 'The Lion and the Mouse' by Jerry Pinkney (Watercolor) as an illustration

Category      Medium      Name                   Artist
--------      ------      ----                   ------
Illustrations Lithography The Funny Thing        Wanda Gág
Illustrations Unknown     Millions of Cats       Wanda Gág
Illustrations Watercolor  The Lion and the Mouse Jerry Pinkney

VERBOSE: Adding work 'The Funny Thing' to works list
VERBOSE: Adding artist 'Wanda Gág' to artists list
VERBOSE: Adding illustrator 'Wanda Gág' to artists list
VERBOSE: Adding work 'Millions of Cats' to works list
VERBOSE: Artist 'Wanda Gág' already registered.
VERBOSE: Illustrator 'Wanda Gág' already registered.
VERBOSE: Adding work 'The Lion and the Mouse' to works list
VERBOSE: Adding artist 'Jerry Pinkney' to artists list
VERBOSE: Adding illustrator 'Jerry Pinkney' to artists list

VERBOSE: Work 'The Funny Thing' already registered.
VERBOSE: Artist 'Wanda Gág' already registered.
VERBOSE: Work 'Millions of Cats' already registered.
VERBOSE: Artist 'Wanda Gág' already registered.
VERBOSE: Work 'The Lion and the Mouse' already registered.
VERBOSE: Artist 'Jerry Pinkney' already registered.

Published work artists: Pink Floyd, Wu-Tang Clan, Wanda Gág, Jerry Pinkney

Illustration artists: Wanda Gág, Jerry Pinkney
```

The verbose messaging from creating the instances shows that:

+   When creating the first instance, the base class default constructor was called before the derived class default constructor.
+   When creating the second instance, the explicitly inherited constructor was called for the base class before the derived class constructor.
+   When creating the third instance, the base class default constructor was called before the derived class constructor.

The verbose messages from the `RegisterWork()` method indicate that the works and artists were already registered. This is because the `RegisterIllustration()` method called the `RegisterWork()` method internally.

However, when comparing the value of the static **Artist** property for both the base class and derived class, the values are different. The **Artists** property for the derived class only includes illustrators, not the album artists. Redefining the **Artist** property in the derived class prevents the class from returning the static property on the base class.

The final code block calls the `ToString()` method on the entries of the static **List** property on the base class.

PowerShell

```powershell
[PublishedWork]::List | ForEach-Object -Process { $_.ToString() }
```

Output

```Output
The Dark Side of the Moon by Pink Floyd
The Wall by Pink Floyd
36 Chambers by Wu-Tang Clan
The Funny Thing by Wanda Gág (Lithography)
Millions of Cats by Wanda Gág (Unknown)
The Lion and the Mouse by Jerry Pinkney (Watercolor)
```

The **Album** instances only return the name and artist in their string. The **Illustration** instances also included the medium in parentheses, because that class overrode the `ToString()` method.

The following example shows how a class can implement one or more interfaces. The example extends the definition of a **Temperature** class to support more operations and behaviors.

Before implementing any interfaces, the **Temperature** class is defined with two properties, **Degrees** and **Scale**. It defines constructors and three instance methods for returning the instance as degrees of a particular scale.

The class defines the available scales with the **TemperatureScale** enumeration.

PowerShell

```powershell
class Temperature {
    [float]            $Degrees
    [TemperatureScale] $Scale

    Temperature() {}
    Temperature([float] $Degrees)          { $this.Degrees = $Degrees }
    Temperature([TemperatureScale] $Scale) { $this.Scale = $Scale }
    Temperature([float] $Degrees, [TemperatureScale] $Scale) {
        $this.Degrees = $Degrees
        $this.Scale   = $Scale
    }

    [float] ToKelvin() {
        switch ($this.Scale) {
            Celsius    { return $this.Degrees + 273.15 }
            Fahrenheit { return ($this.Degrees + 459.67) * 5/9 }
        }
        return $this.Degrees
    }
    [float] ToCelsius() {
        switch ($this.Scale) {
            Fahrenheit { return ($this.Degrees - 32) * 5/9 }
            Kelvin     { return $this.Degrees - 273.15 }
        }
        return $this.Degrees
    }
    [float] ToFahrenheit() {
        switch ($this.Scale) {
            Celsius    { return $this.Degrees * 9/5 + 32 }
            Kelvin     { return $this.Degrees * 9/5 - 459.67 }
        }
        return $this.Degrees
    }
}

enum TemperatureScale {
    Celsius    = 0
    Fahrenheit = 1
    Kelvin     = 2
}
```

However, in this basic implementation, there's a few limitations as shown in the following example output:

PowerShell

```powershell
$Celsius    = [Temperature]::new()
$Fahrenheit = [Temperature]::new([TemperatureScale]::Fahrenheit)
$Kelvin     = [Temperature]::new(0, 'Kelvin')

$Celsius, $Fahrenheit, $Kelvin

"The temperatures are: $Celsius, $Fahrenheit, $Kelvin"

[Temperature]::new() -eq $Celsius

$Celsius -gt $Kelvin
```

Output

```Output
Degrees      Scale
-------      -----
   0.00    Celsius
   0.00 Fahrenheit
   0.00     Kelvin

The temperatures are: Temperature, Temperature, Temperature

False

InvalidOperation:
Line |
  11 |  $Celsius -gt $Kelvin
     |  ~~~~~~~~~~~~~~~~~~~~
     | Cannot compare "Temperature" because it is not IComparable.
```

The output shows that instances of **Temperature**:

+   Don't display correctly as strings.
+   Can't be checked properly for equivalency.
+   Can't be compared.

These three problems can be addressed by implementing interfaces for the class.

The first interface to implement for the **Temperature** class is **System.IFormattable**. This interface enables formatting an instance of the class as different strings. To implement the interface, the class needs to inherit from **System.IFormattable** and define the `ToString()` instance method.

The `ToString()` instance method needs to have the following signature:

PowerShell

```powershell
[string] ToString(
    [string]$Format,
    [System.IFormatProvider]$FormatProvider
) {
    # Implementation
}
```

The signature that the interface requires is listed in the [reference documentation](https://learn.microsoft.com/en-us/dotnet/api/system.iformattable#methods).

For **Temperature**, the class should support three formats: `C` to return the instance in Celsius, `F` to return it in Fahrenheit, and `K` to return it in Kelvin. For any other format, the method should throw a **System.FormatException**.

PowerShell

```powershell
[string] ToString(
    [string]$Format,
    [System.IFormatProvider]$FormatProvider
) {
    # If format isn't specified, use the defined scale.
    if ([string]::IsNullOrEmpty($Format)) {
        $Format = switch ($this.Scale) {
            Celsius    { 'C' }
            Fahrenheit { 'F' }
            Kelvin     { 'K' }
        }
    }
    # If format provider isn't specified, use the current culture.
    if ($null -eq $FormatProvider) {
        $FormatProvider = [cultureinfo]::CurrentCulture
    }
    # Format the temperature.
    switch ($Format) {
        'C' {
            return $this.ToCelsius().ToString('F2', $FormatProvider) + '°C'
        }
        'F' {
            return $this.ToFahrenheit().ToString('F2', $FormatProvider) + '°F'
        }
        'K' {
            return $this.ToKelvin().ToString('F2', $FormatProvider) + '°K'
        }
    }
    # If we get here, the format is invalid.
    throw [System.FormatException]::new(
        "Unknown format: '$Format'. Valid Formats are 'C', 'F', and 'K'"
    )
}
```

In this implementation, the method defaults to the instance scale for format and the current culture when formatting the numerical degree value itself. It uses the `To<Scale>()` instance methods to convert the degrees, formats them to two-decimal places, and appends the appropriate degree symbol to the string.

With the required signature implemented, the class can also define overloads to make it easier to return the formatted instance.

PowerShell

```powershell
[string] ToString([string]$Format) {
    return $this.ToString($Format, $null)
}

[string] ToString() {
    return $this.ToString($null, $null)
}
```

The following code shows the updated definition for **Temperature**:

PowerShell

```powershell
class Temperature : System.IFormattable {
    [float]            $Degrees
    [TemperatureScale] $Scale

    Temperature() {}
    Temperature([float] $Degrees)          { $this.Degrees = $Degrees }
    Temperature([TemperatureScale] $Scale) { $this.Scale = $Scale }
    Temperature([float] $Degrees, [TemperatureScale] $Scale) {
        $this.Degrees = $Degrees
        $this.Scale = $Scale
    }

    [float] ToKelvin() {
        switch ($this.Scale) {
            Celsius { return $this.Degrees + 273.15 }
            Fahrenheit { return ($this.Degrees + 459.67) * 5 / 9 }
        }
        return $this.Degrees
    }
    [float] ToCelsius() {
        switch ($this.Scale) {
            Fahrenheit { return ($this.Degrees - 32) * 5 / 9 }
            Kelvin { return $this.Degrees - 273.15 }
        }
        return $this.Degrees
    }
    [float] ToFahrenheit() {
        switch ($this.Scale) {
            Celsius { return $this.Degrees * 9 / 5 + 32 }
            Kelvin { return $this.Degrees * 9 / 5 - 459.67 }
        }
        return $this.Degrees
    }

    [string] ToString(
        [string]$Format,
        [System.IFormatProvider]$FormatProvider
    ) {
        # If format isn't specified, use the defined scale.
        if ([string]::IsNullOrEmpty($Format)) {
            $Format = switch ($this.Scale) {
                Celsius    { 'C' }
                Fahrenheit { 'F' }
                Kelvin     { 'K' }
            }
        }
        # If format provider isn't specified, use the current culture.
        if ($null -eq $FormatProvider) {
            $FormatProvider = [cultureinfo]::CurrentCulture
        }
        # Format the temperature.
        switch ($Format) {
            'C' {
                return $this.ToCelsius().ToString('F2', $FormatProvider) + '°C'
            }
            'F' {
                return $this.ToFahrenheit().ToString('F2', $FormatProvider) + '°F'
            }
            'K' {
                return $this.ToKelvin().ToString('F2', $FormatProvider) + '°K'
            }
        }
        # If we get here, the format is invalid.
        throw [System.FormatException]::new(
            "Unknown format: '$Format'. Valid Formats are 'C', 'F', and 'K'"
        )
    }

    [string] ToString([string]$Format) {
        return $this.ToString($Format, $null)
    }

    [string] ToString() {
        return $this.ToString($null, $null)
    }
}

enum TemperatureScale {
    Celsius    = 0
    Fahrenheit = 1
    Kelvin     = 2
}
```

The output for the method overloads is shown in the following block.

PowerShell

```powershell
$Temp = [Temperature]::new()
"The temperature is $Temp"
$Temp.ToString()
$Temp.ToString('K')
$Temp.ToString('F', $null)
```

Output

```Output
The temperature is 0.00°C

0.00°C

273.15°K

32.00°F
```

Now that the **Temperature** class can be formatted for readability, users need be able to check whether two instances of the class are equal. To support this test, the class needs to implement the **System.IEquatable** interface.

To implement the interface, the class needs to inherit from **System.IEquatable** and define the `Equals()` instance method. The `Equals()` method needs to have the following signature:

PowerShell

```powershell
[bool] Equals([Object]$Other) {
    # Implementation
}
```

The signature that the interface requires is listed in the [reference documentation](https://learn.microsoft.com/en-us/dotnet/api/system.iequatable-1#methods).

For **Temperature**, the class should only support comparing two instances of the class. For any other value or type, including `$null`, it should return `$false`. When comparing two temperatures, the method should convert both values to Kelvin, since temperatures can be equivalent even with different scales.

PowerShell

```powershell
[bool] Equals([Object]$Other) {
    # If the other object is null, we can't compare it.
    if ($null -eq $Other) {
        return $false
    }

    # If the other object isn't a temperature, we can't compare it.
    $OtherTemperature = $Other -as [Temperature]
    if ($null -eq $OtherTemperature) {
        return $false
    }

    # Compare the temperatures as Kelvin.
    return $this.ToKelvin() -eq $OtherTemperature.ToKelvin()
}
```

With the interface method implemented, the updated definition for **Temperature** is:

PowerShell

```powershell
class Temperature : System.IFormattable, System.IEquatable[Object] {
    [float]            $Degrees
    [TemperatureScale] $Scale

    Temperature() {}
    Temperature([float] $Degrees)          { $this.Degrees = $Degrees }
    Temperature([TemperatureScale] $Scale) { $this.Scale = $Scale }
    Temperature([float] $Degrees, [TemperatureScale] $Scale) {
        $this.Degrees = $Degrees
        $this.Scale = $Scale
    }

    [float] ToKelvin() {
        switch ($this.Scale) {
            Celsius { return $this.Degrees + 273.15 }
            Fahrenheit { return ($this.Degrees + 459.67) * 5 / 9 }
        }
        return $this.Degrees
    }
    [float] ToCelsius() {
        switch ($this.Scale) {
            Fahrenheit { return ($this.Degrees - 32) * 5 / 9 }
            Kelvin { return $this.Degrees - 273.15 }
        }
        return $this.Degrees
    }
    [float] ToFahrenheit() {
        switch ($this.Scale) {
            Celsius { return $this.Degrees * 9 / 5 + 32 }
            Kelvin { return $this.Degrees * 9 / 5 - 459.67 }
        }
        return $this.Degrees
    }

    [string] ToString(
        [string]$Format,
        [System.IFormatProvider]$FormatProvider
    ) {
        # If format isn't specified, use the defined scale.
        if ([string]::IsNullOrEmpty($Format)) {
            $Format = switch ($this.Scale) {
                Celsius    { 'C' }
                Fahrenheit { 'F' }
                Kelvin     { 'K' }
            }
        }
        # If format provider isn't specified, use the current culture.
        if ($null -eq $FormatProvider) {
            $FormatProvider = [cultureinfo]::CurrentCulture
        }
        # Format the temperature.
        switch ($Format) {
            'C' {
                return $this.ToCelsius().ToString('F2', $FormatProvider) + '°C'
            }
            'F' {
                return $this.ToFahrenheit().ToString('F2', $FormatProvider) + '°F'
            }
            'K' {
                return $this.ToKelvin().ToString('F2', $FormatProvider) + '°K'
            }
        }
        # If we get here, the format is invalid.
        throw [System.FormatException]::new(
            "Unknown format: '$Format'. Valid Formats are 'C', 'F', and 'K'"
        )
    }

    [string] ToString([string]$Format) {
        return $this.ToString($Format, $null)
    }

    [string] ToString() {
        return $this.ToString($null, $null)
    }

    [bool] Equals([Object]$Other) {
        # If the other object is null, we can't compare it.
        if ($null -eq $Other) {
            return $false
        }

        # If the other object isn't a temperature, we can't compare it.
        $OtherTemperature = $Other -as [Temperature]
        if ($null -eq $OtherTemperature) {
            return $false
        }

        # Compare the temperatures as Kelvin.
        return $this.ToKelvin() -eq $OtherTemperature.ToKelvin()
    }
}

enum TemperatureScale {
    Celsius    = 0
    Fahrenheit = 1
    Kelvin     = 2
}
```

The following block shows how the updated class behaves:

PowerShell

```powershell
$Celsius    = [Temperature]::new()
$Fahrenheit = [Temperature]::new(32, 'Fahrenheit')
$Kelvin     = [Temperature]::new([TemperatureScale]::Kelvin)

@"
Temperatures are: $Celsius, $Fahrenheit, $Kelvin
`$Celsius.Equals(`$Fahrenheit) = $($Celsius.Equals($Fahrenheit))
`$Celsius -eq `$Fahrenheit     = $($Celsius -eq $Fahrenheit)
`$Celsius -ne `$Kelvin         = $($Celsius -ne $Kelvin)
"@
```

Output

```Output
Temperatures are: 0.00°C, 32.00°F, 0.00°K

$Celsius.Equals($Fahrenheit) = True
$Celsius -eq $Fahrenheit     = True
$Celsius -ne $Kelvin         = True
```

The last interface to implement for the **Temperature** class is **System.IComparable**. When the class implements this interface, users can use the `-lt`, `-le`, `-gt`, and `-ge` operators to compare instances of the class.

To implement the interface, the class needs to inherit from **System.IComparable** and define the `Equals()` instance method. The `Equals()` method needs to have the following signature:

PowerShell

```powershell
[int] CompareTo([Object]$Other) {
    # Implementation
}
```

The signature that the interface requires is listed in the [reference documentation](https://learn.microsoft.com/en-us/dotnet/api/system.icomparable#methods).

For **Temperature**, the class should only support comparing two instances of the class. Because the underlying type for the **Degrees** property, even when converted to a different scale, is a floating point number, the method can rely on the underlying type for the actual comparison.

PowerShell

```powershell
[int] CompareTo([Object]$Other) {
    # If the other object's null, consider this instance "greater than" it
    if ($null -eq $Other) {
        return 1
    }
    # If the other object isn't a temperature, we can't compare it.
    $OtherTemperature = $Other -as [Temperature]
    if ($null -eq $OtherTemperature) {
        throw [System.ArgumentException]::new(
            "Object must be of type 'Temperature'."
        )
    }
    # Compare the temperatures as Kelvin.
    return $this.ToKelvin().CompareTo($OtherTemperature.ToKelvin())
}
```

The final definition for the **Temperature** class is:

PowerShell

```powershell
class Temperature : System.IFormattable,
                    System.IComparable,
                    System.IEquatable[Object] {
    # Instance properties
    [float]            $Degrees
    [TemperatureScale] $Scale

    # Constructors
    Temperature() {}
    Temperature([float] $Degrees)          { $this.Degrees = $Degrees }
    Temperature([TemperatureScale] $Scale) { $this.Scale = $Scale }
    Temperature([float] $Degrees, [TemperatureScale] $Scale) {
        $this.Degrees = $Degrees
        $this.Scale = $Scale
    }

    [float] ToKelvin() {
        switch ($this.Scale) {
            Celsius { return $this.Degrees + 273.15 }
            Fahrenheit { return ($this.Degrees + 459.67) * 5 / 9 }
        }
        return $this.Degrees
    }
    [float] ToCelsius() {
        switch ($this.Scale) {
            Fahrenheit { return ($this.Degrees - 32) * 5 / 9 }
            Kelvin { return $this.Degrees - 273.15 }
        }
        return $this.Degrees
    }
    [float] ToFahrenheit() {
        switch ($this.Scale) {
            Celsius { return $this.Degrees * 9 / 5 + 32 }
            Kelvin { return $this.Degrees * 9 / 5 - 459.67 }
        }
        return $this.Degrees
    }

    [string] ToString(
        [string]$Format,
        [System.IFormatProvider]$FormatProvider
    ) {
        # If format isn't specified, use the defined scale.
        if ([string]::IsNullOrEmpty($Format)) {
            $Format = switch ($this.Scale) {
                Celsius    { 'C' }
                Fahrenheit { 'F' }
                Kelvin     { 'K' }
            }
        }
        # If format provider isn't specified, use the current culture.
        if ($null -eq $FormatProvider) {
            $FormatProvider = [cultureinfo]::CurrentCulture
        }
        # Format the temperature.
        switch ($Format) {
            'C' {
                return $this.ToCelsius().ToString('F2', $FormatProvider) + '°C'
            }
            'F' {
                return $this.ToFahrenheit().ToString('F2', $FormatProvider) + '°F'
            }
            'K' {
                return $this.ToKelvin().ToString('F2', $FormatProvider) + '°K'
            }
        }
        # If we get here, the format is invalid.
        throw [System.FormatException]::new(
            "Unknown format: '$Format'. Valid Formats are 'C', 'F', and 'K'"
        )
    }

    [string] ToString([string]$Format) {
        return $this.ToString($Format, $null)
    }

    [string] ToString() {
        return $this.ToString($null, $null)
    }

    [bool] Equals([Object]$Other) {
        # If the other object is null, we can't compare it.
        if ($null -eq $Other) {
            return $false
        }

        # If the other object isn't a temperature, we can't compare it.
        $OtherTemperature = $Other -as [Temperature]
        if ($null -eq $OtherTemperature) {
            return $false
        }

        # Compare the temperatures as Kelvin.
        return $this.ToKelvin() -eq $OtherTemperature.ToKelvin()
    }
    [int] CompareTo([Object]$Other) {
        # If the other object's null, consider this instance "greater than" it
        if ($null -eq $Other) {
            return 1
        }
        # If the other object isn't a temperature, we can't compare it.
        $OtherTemperature = $Other -as [Temperature]
        if ($null -eq $OtherTemperature) {
            throw [System.ArgumentException]::new(
                "Object must be of type 'Temperature'."
            )
        }
        # Compare the temperatures as Kelvin.
        return $this.ToKelvin().CompareTo($OtherTemperature.ToKelvin())
    }
}

enum TemperatureScale {
    Celsius    = 0
    Fahrenheit = 1
    Kelvin     = 2
}
```

With the full definition, users can format and compare instances of the class in PowerShell like any builtin type.

PowerShell

```powershell
$Celsius    = [Temperature]::new()
$Fahrenheit = [Temperature]::new(32, 'Fahrenheit')
$Kelvin     = [Temperature]::new([TemperatureScale]::Kelvin)

@"
Temperatures are: $Celsius, $Fahrenheit, $Kelvin
`$Celsius.Equals(`$Fahrenheit)    = $($Celsius.Equals($Fahrenheit))
`$Celsius.Equals(`$Kelvin)        = $($Celsius.Equals($Kelvin))
`$Celsius.CompareTo(`$Fahrenheit) = $($Celsius.CompareTo($Fahrenheit))
`$Celsius.CompareTo(`$Kelvin)     = $($Celsius.CompareTo($Kelvin))
`$Celsius -lt `$Fahrenheit        = $($Celsius -lt $Fahrenheit)
`$Celsius -le `$Fahrenheit        = $($Celsius -le $Fahrenheit)
`$Celsius -eq `$Fahrenheit        = $($Celsius -eq $Fahrenheit)
`$Celsius -gt `$Kelvin            = $($Celsius -gt $Kelvin)
"@
```

Output

```Output
Temperatures are: 0.00°C, 32.00°F, 0.00°K
$Celsius.Equals($Fahrenheit)    = True
$Celsius.Equals($Kelvin)        = False
$Celsius.CompareTo($Fahrenheit) = 0
$Celsius.CompareTo($Kelvin)     = 1
$Celsius -lt $Fahrenheit        = False
$Celsius -le $Fahrenheit        = True
$Celsius -eq $Fahrenheit        = True
$Celsius -gt $Kelvin            = True
```

This example shows how you can derive from a generic type as long as the type parameter is already defined at parse time.

Run the following code block. It shows how a new class can inherit from a generic type as long as the type parameter is already defined at parse time.

PowerShell

```powershell
class ExampleStringList : System.Collections.Generic.List[string] {}

$List = [ExampleStringList]::new()
$List.AddRange([string[]]@('a','b','c'))
$List.GetType() | Format-List -Property Name, BaseType
$List
```

Output

```Output
Name     : ExampleStringList
BaseType : System.Collections.Generic.List`1[System.String]

a
b
c
```

The next code block first defines a new class, **ExampleItem**, with a single instance property and the `ToString()` method. Then it defines the **ExampleItemList** class inheriting from the **System.Collections.Generic.List** base class with **ExampleItem** as the type parameter.

Copy the entire code block and run it as a single statement.

PowerShell

```powershell
class ExampleItem {
    [string] $Name
    [string] ToString() { return $this.Name }
}
class ExampleItemList : System.Collections.Generic.List[ExampleItem] {}
```

Output

```Output
ParentContainsErrorRecordException: An error occurred while creating the pipeline.
```

Running the entire code block raises an error because PowerShell hasn't loaded the **ExampleItem** class into the runtime yet. You can't use class name as the type parameter for the **System.Collections.Generic.List** base class yet.

Run the following code blocks in the order they're defined.

PowerShell

```powershell
class ExampleItem {
    [string] $Name
    [string] ToString() { return $this.Name }
}
```

PowerShell

```powershell
class ExampleItemList : System.Collections.Generic.List[ExampleItem] {}
```

This time, PowerShell doesn't raise any errors. Both classes are now defined. Run the following code block to view the behavior of the new class.

PowerShell

```powershell
$List = [ExampleItemList]::new()
$List.AddRange([ExampleItem[]]@(
    [ExampleItem]@{ Name = 'Foo' }
    [ExampleItem]@{ Name = 'Bar' }
    [ExampleItem]@{ Name = 'Baz' }
))
$List.GetType() | Format-List -Property Name, BaseType
$List
```

Output

```output
Name     : ExampleItemList
BaseType : System.Collections.Generic.List`1[ExampleItem]

Name
----
Foo
Bar
Baz
```

The following code blocks show how you can define a class that inherits from a generic base class that uses a custom type for the type parameter.

Save the following code block as `GenericExample.psd1`.

PowerShell

```powershell
@{
    RootModule        = 'GenericExample.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '2779fa60-0b3b-4236-b592-9060c0661ac2'
}
```

Save the following code block as `GenericExample.InventoryItem.psm1`.

PowerShell

```powershell
class InventoryItem {
    [string] $Name
    [int]    $Count

    InventoryItem() {}
    InventoryItem([string]$Name) {
        $this.Name = $Name
    }
    InventoryItem([string]$Name, [int]$Count) {
        $this.Name  = $Name
        $this.Count = $Count
    }

    [string] ToString() {
        return "$($this.Name) ($($this.Count))"
    }
}
```

Save the following code block as `GenericExample.psm1`.

PowerShell

```powershell
using namespace System.Collections.Generic
using module ./GenericExample.InventoryItem.psm1

class Inventory : List[InventoryItem] {}

# Define the types to export with type accelerators.
$ExportableTypes =@(
    [InventoryItem]
    [Inventory]
)
# Get the internal TypeAccelerators class to use its static methods.
$TypeAcceleratorsClass = [psobject].Assembly.GetType(
    'System.Management.Automation.TypeAccelerators'
)
# Ensure none of the types would clobber an existing type accelerator.
# If a type accelerator with the same name exists, throw an exception.
$ExistingTypeAccelerators = $TypeAcceleratorsClass::Get
foreach ($Type in $ExportableTypes) {
    if ($Type.FullName -in $ExistingTypeAccelerators.Keys) {
        $Message = @(
            "Unable to register type accelerator '$($Type.FullName)'"
            'Accelerator already exists.'
        ) -join ' - '

        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($Message),
            'TypeAcceleratorAlreadyExists',
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $Type.FullName
        )
    }
}
# Add type accelerators for every exportable type.
foreach ($Type in $ExportableTypes) {
    $TypeAcceleratorsClass::Add($Type.FullName, $Type)
}
# Remove type accelerators when the module is removed.
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    foreach($Type in $ExportableTypes) {
        $TypeAcceleratorsClass::Remove($Type.FullName)
    }
}.GetNewClosure()
```

Tip

The root module adds the custom types to PowerShell's type accelerators. This pattern enables module users to immediately access IntelliSense and autocomplete for the custom types without needing to use the `using module` statement first.

For more information about this pattern, see the "Exporting with type accelerators" section of [about\_Classes](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_classes?view=powershell-7.6#export-classes-with-type-accelerators).

Import the module and verify the output.

PowerShell

```powershell
Import-Module ./GenericExample.psd1

$Inventory = [Inventory]::new()
$Inventory.GetType() | Format-List -Property Name, BaseType

$Inventory.Add([InventoryItem]::new('Bucket', 2))
$Inventory.Add([InventoryItem]::new('Mop'))
$Inventory.Add([InventoryItem]@{ Name = 'Broom' ; Count = 4 })
$Inventory
```

Output

```Output
Name     : Inventory
BaseType : System.Collections.Generic.List`1[InventoryItem]

Name   Count
----   -----
Bucket     2
Mop        0
Broom      4
```

The module loads without errors because the **InventoryItem** class is defined in a different module file than the **Inventory** class. Both classes are available to module users.

When a class inherits from a base class, it inherits the properties and methods of the base class. It doesn't inherit the base class constructors directly, but it can call them.

When the base class is defined in .NET rather than PowerShell, note that:

+   PowerShell classes can't inherit from sealed classes.
+   When inheriting from a generic base class, the type parameter for the generic class can't be the derived class. Using the derived class as the type parameter raises a parse error.

To see how inheritance and overriding works for derived classes, see [Example 1](#example-1---inheriting-and-overriding-from-a-base-class).

Derived classes don't directly inherit the constructors of the base class. If the base class defines a default constructor and the derived class doesn't define any constructors, new instances of the derived class use the base class default constructor. If the base class doesn't define a default constructor, derived class must explicitly define at least one constructor.

Derived class constructors can invoke a constructor from the base class with the `base` keyword. If the derived class doesn't explicitly invoke a constructor from the base class, it invokes the default constructor for the base class instead.

To invoke a nondefault base constructor, add `: base(<parameters>)` after the constructor parameters and before the body block.

Syntax

```Syntax
class <derived-class> : <base-class> {
    <derived-class>(<derived-parameters>) : <base-class>(<base-parameters>) {
        # initialization code
    }
}
```

When defining a constructor that calls a base class constructor, the parameters can be any of the following items:

+   The variable of any parameter on the derived class constructor.
+   Any static value.
+   Any expression that evaluates to a value of the parameter type.

The **Illustration** class in [Example 1](#example-1---inheriting-and-overriding-from-a-base-class) shows how a derived class can use the base class constructors.

When a class derives from a base class, it inherits the methods of the base class and their overloads. Any method overloads defined on the base class, including hidden methods, are available on the derived class.

A derived class can override an inherited method overload by redefining it in the class definition. To override the overload, the parameter types must be the same as for the base class. The output type for the overload can be different.

Unlike constructors, methods can't use the `: base(<parameters>)` syntax to invoke a base class overload for the method. The redefined overload on the derived class completely replaces the overload defined by the base class. To call the base class method for an instance, cast the instance variable (`$this`) to the base class before calling the method.

The following snippet shows how a derived class can call the base class method.

PowerShell

```powershell
class BaseClass {
    [bool] IsTrue() { return $true }
}
class DerivedClass : BaseClass {
    [bool] IsTrue()     { return $false }
    [bool] BaseIsTrue() { return ([BaseClass]$this).IsTrue() }
}

@"
[BaseClass]::new().IsTrue()        = $([BaseClass]::new().IsTrue())
[DerivedClass]::new().IsTrue()     = $([DerivedClass]::new().IsTrue())
[DerivedClass]::new().BaseIsTrue() = $([DerivedClass]::new().BaseIsTrue())
"@
```

Output

```Output
[BaseClass]::new().IsTrue()        = True
[DerivedClass]::new().IsTrue()     = False
[DerivedClass]::new().BaseIsTrue() = True
```

For an extended sample showing how a derived class can override inherited methods, see the **Illustration** class in [Example 1](#example-1---inheriting-and-overriding-from-a-base-class).

When a class derives from a base class, it inherits the properties of the base class. Any properties defined on the base class, including hidden properties, are available on the derived class.

A derived class can override an inherited property by redefining it in the class definition. The property on the derived class uses the redefined type and default value, if any. If the inherited property defined a default value and the redefined property doesn't, the inherited property has no default value.

If a derived class doesn't override a static property, accessing the static property through the derived class accesses the static property of the base class. Modifying the property value through the derived class modifies the value on the base class. Any other derived class that doesn't override the static property also uses the value of the property on the base class. Updating the value of an inherited static property in a class that doesn't override the property might have unintended effects for classes derived from the same base class.

[Example 1](#example-1---inheriting-and-overriding-from-a-base-class) shows how derived classes that inherit, extend, and override the base class properties.

When a class derives from a generic, the type parameter must already be defined before PowerShell parses the derived class. If the type parameter for the generic is a PowerShell class or enumeration defined in the same file or code block, PowerShell raises an error.

To derive a class from a generic base class with a custom type as the type parameter, define the class or enumeration for the type parameter in a different file or module and use the `using module` statement to load the type definition.

For an example showing how to inherit from a generic base class, see [Example 3](#example-3---inheriting-from-a-generic-base-class).

There are a few classes that can be useful to inherit when authoring PowerShell modules. This section lists a few base classes and what a class derived from them can be used for.

+   **System.Attribute** - Derive classes to define attributes that can be used for variables, parameters, class and enumeration definitions, and more.
+   **System.Management.Automation.ArgumentTransformationAttribute** - Derive classes to handle converting input for a variable or parameter into a specific data type.
+   **System.Management.Automation.ValidateArgumentsAttribute** - Derive classes to apply custom validation to variables, parameters, and class properties.
+   **System.Collections.Generic.List** - Derive classes to make creating and managing lists of a specific data type easier.
+   **System.Exception** - Derive classes to define custom errors.

A PowerShell class that implements an interface must implement all the members of that interface. Omitting the implementation interface members causes a parse-time error in the script.

Note

PowerShell doesn't support declaring new interfaces in PowerShell script. Instead, interfaces must be declared in .NET code and added to the session with the `Add-Type` cmdlet or the `using assembly` statement.

When a class implements an interface, it can be used like any other class that implements that interface. Some commands and operations limit their supported types to classes that implement a specific interface.

To review a sample implementation of interfaces, see [Example 2](#example-2---implementing-interfaces).

There are a few interface classes that can be useful to inherit when authoring PowerShell modules. This section lists a few base classes and what a class derived from them can be used for.

+   **System.IEquatable** - This interface enables users to compare two instances of the class. When a class doesn't implement this interface, PowerShell checks for equivalency between two instances using reference equality. In other words, an instance of the class only equals itself, even if the property values on two instances are the same.
+   **System.IComparable** - This interface enables users to compare instances of the class with the `-le`, `-lt`, `-ge`, and `-gt` comparison operators. When a class doesn't implement this interface, those operators raise an error.
+   **System.IFormattable** - This interface enables users to format instances of the class into different strings. This is useful for classes that have more than one standard string representation, like budget items, bibliographies, and temperatures.
+   **System.IConvertible** - This interface enables users to convert instances of the class to other runtime types. This is useful for classes that have an underlying numerical value or can be converted to one.

+   PowerShell doesn't support defining interfaces in script code.

    Workaround: Define interfaces in C# and reference the assembly that defines the interfaces.

+   PowerShell classes can only inherit from one base class.

    Workaround: Class inheritance is transitive. A derived class can inherit from another derived class to get the properties and methods of a base class.

+   When inheriting from a generic class or interface, the type parameter for the generic must already be defined. A class can't define itself as the type parameter for a class or interface.

    Workaround: To derive from a generic base class or interface, define the custom type in a different `.psm1` file and use the `using module` statement to load the type. There's no workaround for a custom type to use itself as the type parameter when inheriting from a generic.

---

## PsCraft Examples

The following examples are extracted directly from the PsCraft implementation under `Private/`. They show how the project uses inheritance — extending .NET base classes, extending another PowerShell class, extending a generic .NET collection, and the "inheriting from an external module's class" pattern.

### Example 1 — `AliasVisitor : System.Management.Automation.Language.AstVisitor`

[AliasVisitor](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L11-L121) extends the .NET `AstVisitor` so that PowerShell can use it as the callback for `Ast.Visit()`. The base type lives in `System.Management.Automation.Language`, which is **always** resolvable at parse time, so the inheritance is unambiguous.

```powershell
using namespace System.Management.Automation.Language

class AliasVisitor : System.Management.Automation.Language.AstVisitor {
  [string]$Parameter = $null
  [string]$Command = $null
  [string]$Name = $null
  [string]$Value = $null
  [string]$Scope = $null
  [System.Collections.Generic.HashSet[string]]$Aliases = @()

  # Parameter Names
  [AstVisitAction] VisitCommandParameter([CommandParameterAst]$ast) {
    $this.Parameter = $ast.ParameterName
    return [AstVisitAction]::Continue
  }

  # Parameter Values
  [AstVisitAction] VisitStringConstantExpression([StringConstantExpressionAst]$ast) {
    if (!$this.Command) {
      $this.Command = $ast.Value
      return [AstVisitAction]::Continue
    }
    # ...dispatch to $this.Name / $this.Value / $this.Scope
    return [AstVisitAction]::Continue
  }

  [AstVisitAction] VisitFunctionDefinition([FunctionDefinitionAst]$ast) {
    @($ast.Body.ParamBlock.Attributes.Where{ $_.TypeName.Name -eq 'Alias' }.PositionalArguments.Value).ForEach{
      if ($_) { $this.Aliases.Add($_) }
    }
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitCommand([CommandAst]$ast) {
    if ($ast.CommandElements[0].Value -imatch '(New|Set|Remove)-Alias') {
      $ast.Visit($this.ClearParameters())
      # ...
    }
    return [AstVisitAction]::SkipChildren
  }
}
```

The four `Visit*` methods are the standard `AstVisitor` contract — every override returns a `[AstVisitAction]` of `Continue`, `SkipChildren`, or `StopVisit` to control the traversal.

---

### Example 2 — `PsCraft : Microsoft.PowerShell.Commands.ModuleCmdletBase`

[PsCraft](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L613-L828) is the build-engine superclass. It inherits from `ModuleCmdletBase` (a class shipped inside `System.Management.Automation`) so that every method automatically has access to the `WriteVerbose`, `WriteError`, `ThrowTerminatingError`, `ShouldProcess`, etc. helpers that real cmdlets use.

```powershell
class PsCraft : Microsoft.PowerShell.Commands.ModuleCmdletBase {
  [ValidateNotNullOrWhiteSpace()][string]$ModuleName
  [ValidateNotNullOrWhiteSpace()][string]$BuildOutputPath
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$RootPath
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$TestsPath
  [ValidateNotNullOrEmpty()][version]$ModuleVersion
  [ValidateNotNullOrEmpty()][System.IO.FileInfo]$dataFile
  [ValidateNotNullOrEmpty()][System.IO.FileInfo]$buildFile
  [IO.DirectoryInfo]$LocalPSRepo
  [PsObject]$LocalizedData
  [System.Management.Automation.PSCmdlet]$CallerCmdlet
  [bool]$UseVerbose
  [BuildContext]$BuildContext
  [System.Collections.Generic.List[string]]$TaskList

  PsCraft() {}
  PsCraft([string]$RootPath) { [void][PsCraft]::From($RootPath, $this) }

  static [PsCraft] Create()                      { return [PsCraft]::From((Resolve-Path .).Path, $null) }
  static [PsCraft] Create([string]$RootPath)    { return [PsCraft]::From($RootPath, $null) }

  static [PsCraft] From([string]$RootPath, [ref]$o) {
    $b = [PsCraft]::new();
    [Net.ServicePointManager]::SecurityProtocol = [PsCraft]::GetSecurityProtocol();
    # ... wire up BuildContext, RootPath, BuildOutputPath, dataFile, etc.
    if ($null -ne $o) {
      $o.value.GetType().GetProperties().ForEach({
          $v = $b.$($_.Name)
          if ($null -ne $v) { $o.value.$($_.Name) = $v }
        })
      return $o.Value
    }
    return $b
  }
}
```

Because `ModuleCmdletBase` is in `System.Management.Automation`, the inheritance is always parse-time resolvable.

---

### Example 3 — `BuildOrchestrator : PsCraft`

[BuildOrchestrator](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L835-L1557) is the working class that runs `Clean` / `Compile` / `Test` / `Finalize`. It inherits from `PsCraft` (a *PowerShell* class) to reuse all of `PsCraft`'s static utilities (`FormatCode`, `GetSecurityProtocol`, `IsGitRepo`, `UpdateModule`, …) and its base property wire-up.

```powershell
class BuildOrchestrator : PsCraft {
  [string]    $Path
  [string[]]  $RequiredModules
  [System.Management.Automation.PSCmdlet] $Cmdlet
  [System.Management.Automation.ModuleType] $ModuleType = 'Script'
  [bool]      $HasBinarySrc = $false
  [BuildContext] $Context
  [scriptblock] $PSakeScriptBlock = $null
  [BuildSummary] $BuildSummary = $null
  hidden $_runner
  hidden $_logger
  hidden [string] $_logDir

  BuildOrchestrator(
    [string]$path,
    [string[]]$tasks,
    [string[]]$requiredModules,
    [System.Management.Automation.PSCmdlet]$cmdlet
  ) {
    $this.Path = $path
    $this.TaskList = [System.Collections.Generic.List[string]]::new()
    if ($tasks) { $this.TaskList.AddRange($tasks) }
    $this.RequiredModules = $requiredModules
    $this.Cmdlet = $cmdlet
    $this.Context = [BuildContext]::new(
      [IO.DirectoryInfo]::new($path).BaseName, $path, '0.0.0'
    )
    $this.DetectModuleType()
    try { $this._runner = [ThreadRunner]::new() } catch { $this._runner = $null }
    $this.Init_Logger()
  }
  # ...
}
```

Because `PsCraft` exposes `static [PsCraft] Create([string]$RootPath)`, an instance of `BuildOrchestrator` can be created with just one line:

```powershell
$orch = [BuildOrchestrator]::new($path, @('Clean','Compile','Test'), $RequiredMods, $PSCmdlet)
```

…and still has access to all the inherited static helpers from `PsCraft` such as `[PsCraft]::FormatCode($module)` and `[PsCraft]::IsGitRepo($path)`.

---

### Example 4 — `PsModuleData : System.Collections.Generic.Dictionary[string, Object]`

[PsModuleData](file:///d:/GitHub/PsCraft/Private/ModuleData.psm1#L463-L592) is the actual manifest dictionary that holds the key/value pairs that get written to a `.psd1`. It extends the .NET generic dictionary to inherit `Add` / `ContainsKey` / `TryGetValue` / indexer behaviour, and *adds* PowerShell-aware members on top.

```powershell
using namespace System.Collections.ObjectModel

class PsModuleData : System.Collections.Generic.Dictionary[string, Object] {
  [ValidateNotNullOrWhiteSpace()][string]$Name
  [ValidateNotNullOrEmpty()][IO.DirectoryInfo]$Path
  [ReadOnlyCollection[ModuleFile]]$Files
  [ReadOnlyCollection[ModuleFolder]]$Folders
  hidden [PsModuleDefaults]$defaults

  PsModuleData([string]$Name, [System.Management.Automation.ModuleType]$Type, [IO.DirectoryInfo]$Path) {
    $this.Name = [string]::IsNullOrWhiteSpace($Name) `
      ? [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetRandomFileName()) `
      : $Name
    $this.defaults = [PsModuleDefaults]::new($this.Name, $Type, $Path)
    $this.Path = [System.IO.Path]::Combine(
      [PsModuleBase]::GetunResolvedPath($this.GetModuleroot($Path)), $this.Name
    )
    $schema = $this.defaults.GetModuleSchema($this.Name, $Type)
    $this.Files = [PsModuleData]::GetModuleFiles($this.Name, $this.Path, $schema)
    $this.Folders = [PsModuleData]::GetModuleSubFolders($this.Name, $this.Path, $schema)
  }

  [void] Set($k, $v) {
    if ($this.ContainsKey($k)) { $this[$k] = $v } else { $this.Add($k, $v) }
  }
}
```

> **Pitfall:** PowerShell classes do not implement `IDictionary` / `IEnumerable`, so a `PsModuleData` instance does **not** have a `.GetEnumerator()` that PowerShell can call via `foreach` — even though it inherits from `Dictionary[string, Object]`. Use `GetEnumerator()` on the inherited `Keys`/`Values` collection, or expose an explicit accessor like `PsModuleDefaults::GetDefaults()` (see `ModuleData.psm1`).
> See also the "Defining instance methods with `Update-TypeData`" section of `about_Classes_Methods.md` for the workaround pattern.

---

### Example 5 — `ModuleName : PsModuleBase` (scaffolding template)

Every module scaffolded by PsCraft gets a [`RootLoader.ps1`](file:///d:/GitHub/PsCraft/Private/defaults/Script/RootLoader.ps1) file that uses a class that derives from `PsModuleBase` — a class defined in the **external** `PsModuleBase` module.

```powershell
#!/usr/bin/env pwsh
using namespace System.IO
using namespace System.Collections.Generic
using namespace System.Management.Automation

#Requires -Modules PsModuleBase
#Requires -Psedition Core

#region Classes
class ModuleName : PsModuleBase {
  # Define the class. Try constructors, properties, or methods.
}
#endregion Classes

# Types that will be available to users when they import the module.
$typestoExport = @(
  #[ModuleName]
)
$TypeAcceleratorsClass = [PsObject].Assembly.GetType(
  'System.Management.Automation.TypeAccelerators'
)
foreach ($Type in $typestoExport) {
  if ($Type.FullName -in $TypeAcceleratorsClass::Get.Keys) {
    $Message = @(
      "Unable to register type accelerator '$($Type.FullName)'"
      'Accelerator already exists.'
    ) -join ' - '
    "TypeAcceleratorAlreadyExists $Message" | Write-Debug
  }
}
foreach ($Type in $typestoExport) {
  $TypeAcceleratorsClass::Add($Type.FullName, $Type)
}
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
  foreach ($Type in $typestoExport) {
    $TypeAcceleratorsClass::Remove($Type.FullName)
  }
}.GetNewClosure()
```

The `#Requires -Modules PsModuleBase` directive guarantees the base class is loaded before the `class ModuleName : PsModuleBase` line is parsed, so inheritance is parse-time resolvable. The TypeAccelerators registration code is then run after the class is defined.

---

### Important limitation that bit PsCraft: base types must be parse-time resolvable

PowerShell requires a class's base type to be in scope **before** the `class` keyword line is parsed. The `using module` directives at the top of the file, plus `#Requires`, are the only ways to guarantee that.

Concretely, [BuildLogEntry](file:///d:/GitHub/PsCraft/Private/BuildLog.psm1#L9-L30) **cannot** inherit from `LogEntry` (the cliHelper.logger type):

```powershell
# BuildLogEntry is a standalone record type for build-correlated diagnostics.
# NOTE: Cannot inherit from LogEntry (cliHelper.logger type) here because
#       class base-types must be resolvable at parse time via 'using module'.
#       The _logger.LogType assignment is commented out accordingly.
class BuildLogEntry {
  [string]$TaskName
  [string]$ProjectName
  [string]$BuildRunId
  [string]$Severity
  [string]$Message
  [Exception]$Exception

  static [BuildLogEntry] Create([string]$severity, [string]$message) {
    return [BuildLogEntry]::Create($severity, $message, $null)
  }
  static [BuildLogEntry] Create([string]$severity, [string]$message, [Exception]$exception) {
    return [BuildLogEntry]@{
      Severity    = $severity
      Message     = $message
      Exception   = $exception
      TaskName    = ''
      ProjectName = ''
      BuildRunId  = ''
    }
  }
}
```

…and [BuildOrchestrator](file:///d:/GitHub/PsCraft/Private/Orchestrator.psm1#L844-L845) cannot type its hidden fields as `ThreadRunner` / `Logger` for the same reason — they are declared as `hidden $_runner` / `hidden $_logger` (untyped) and assigned at runtime:

```powershell
hidden $_runner   # [ThreadRunner] — typed at runtime; cliHelper.core type not parse-time resolvable as field
hidden $_logger   # [Logger]       — typed at runtime; cliHelper.logger type not parse-time resolvable as field
```

If a base type cannot be made parse-time resolvable, the only safe option is to either (a) declare fields untyped and assign at runtime, or (b) take a dependency on the base type from a `.psm1` file that is always `using module`-loaded before any class that derives from it.

---

### Related

- See [about_Classes_Constructors](about_Classes_Constructors.md) for the constructor patterns that pair with this inheritance (e.g. how `BuildOrchestrator` has its own constructor and does not need to chain into `PsCraft`'s).
- See [about_Classes_Methods](about_Classes_Methods.md) for the static `[PsCraft]::From([string]$RootPath, [ref]$o)` factory pattern that re-uses base-class fields to populate a derived instance.
- See [about_Classes_Properties](about_Classes_Properties.md) for the `Equals` / `GetHashCode` / `ToString` override trio used on `PsModule` to make it usable in collections.
