**docs.PsCraft**

<p>
This PowerShell module is a toolbox to streamline the process of building and distributing PowerShell modules.
</br>
<img align="right" src="https://github.com/user-attachments/assets/92fc736a-118e-45cd-8b9f-0df83d1309f8" width="250" height="250" alt="it_just_works" />
<div align="left">
<b>
  Sometimes I just want something to work and not to have think about it.
</b>
</br>
</br>
<!-- focus on writing code and not get bogged down in intricacies of
the build process. -->
<p>

<p>
This module aims to eliminate the need to <b>write and test build scripts</b>.
The only code you are expected to write is in <a href="/Public/">Public</a> functions and <a href="Tests">Tests</a>.

😔 Tests have to be written by humans. There's just no other way.
</p>
</div>

**The goal is to give you a starting point that just works.**

All you need to do is run 3 commands minimum, then let an LLM take care of the rest.

### Official Documentation
- [About_Modules](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_modules) - Microsoft's official module documentation
- [The Monad Manifesto](https://www.jsnover.com/Docs/MonadManifesto.pdf) - Core PowerShell concepts

### Community Resources
- [The SysAdmin Channel](https://thesysadminchannel.com/powershell-module/) - Practical module development
- [Mike F Robbins' Blog](https://mikefrobbins.com/2018/08/17/powershell-script-module-design-public-private-versus-functions-internal-folders-for-functions/) - Module design patterns
- [PowerShell Modules and Encapsulation](https://www.simple-talk.com/dotnet/.net-tools/further-down-the-rabbit-hole-powershell-modules-and-encapsulation/) - Advanced module concepts


## Getting Started

1. Install and import the module:
```PowerShell
Install-Module PsCraft
Import-Module PsCraft
```

2. Create your first module:
```PowerShell
New-PsModule -Name MyModule
```

![Image](https://github.com/user-attachments/assets/bbc1e8d7-8a0f-410a-8196-cadab1821ae9)

**Example:**

https://github.com/user-attachments/assets/46a1b8d4-8e83-4194-a092-2244d7ef833e

## Additional Features

### Script Signing
Sign your PowerShell scripts for enhanced security:
```PowerShell
Add-Signature -File MyNewScript.ps1
```

### GUI Creation
Create graphical interfaces for your scripts (works on Windows and Linux):
```PowerShell
Add-GUI -Script MyNewScript.ps1
```
