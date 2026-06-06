# **docs.PsCraft**

<p>
This PowerShell module is a toolbox to streamline the process of building and distributing PowerShell modules.
</br>
<img align="right" src="https://github.com/user-attachments/assets/92fc736a-118e-45cd-8b9f-0df83d1309f8" width="250" height="250" alt="it_just_works" />
<div align="left">
<b>
  "Sometimes I just want something to work and not to have think about it."
</b>
</br>
</br>
<!-- focus on writing code and not get bogged down in intricacies of
the build process. -->

</div>


## Table of Contents

- [Overview](#overview)
- [Getting Started](#getting-started)
- [Architecture](#architecture)
  - [Public API Surface](#public-api-surface)
  - [Build Engine & Module Scaffolding](#build-engine--module-scaffolding)
  - [Module Type Templates (`Private/defaults/`)](#module-type-templates-privatedefaults)
- [Public Cmdlets](#public-cmdlets)
- [Internal Domain Classes](#internal-domain-classes)
  - [`Orchestrator.psm1`](#orchestratorpsm1)
  - [`ModuleData.psm1`](#moduledatapm1)
  - [`BuildLog.psm1`](#buildlogpsm1)
  - [`Enums.psm1`](#enumspsm1)
- [Supported Module Types](#supported-module-types)
- [Additional Features](#additional-features)
  - [Script Signing](#script-signing)
  - [GUI Creation](#gui-creation)
- [Dependencies](#dependencies)
  - [Logging — `cliHelper.logger`](#logging--clihelperlogger)
  - [PowerShell Class System](#powershell-class-system)
- [CI/CD Integration](#cicd-integration)
- [Documentation Links](#documentation-links)
- [Community Resources](#community-resources)
- [Previous Bug Fixes](#previous-bug-fixes)


## Overview

PsCraft is a PowerShell module that handles the full lifecycle of a PowerShell module project:

- **Scaffolding** — Generate the project layout for a new module.
- **Schema validation** — Verify that an existing project conforms to the expected layout.
- **Build orchestration** — Compile, test, and package Script, Binary, CIM, and Manifest modules.
- **Distribution** — Publish to the PowerShell Gallery and create GitHub Releases.

The framework is class-based and split into two layers: thin public cmdlets in `Public/` that delegate to domain classes in `Private/`. This separation keeps user-facing API stable while allowing the engine internals to evolve.


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


## Architecture

PsCraft is organized around three logical layers that map directly to the knowledge modules maintained for this project:

```
┌─────────────────────────────────────────────────────────────┐
│  Public API Surface   (Public/*.ps1)                        │
│  - thin cmdlets: Build-Module, New-PsModule, Test-Module,  │
│    Publish-PsModule, Publish-GitHubRelease,                │
│    Get-PSGalleryStatus, Move-ModulePath, Set-BuildVariables│
└────────────────────────┬────────────────────────────────────┘
                         │ delegates to
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Build Engine & Module Scaffolding   (Private/)            │
│  - Orchestrator.psm1: PsModule, PsCraft, BuildOrchestrator,│
│    BuildContext, AliasVisitor, ParseResult                 │
│  - ModuleData.psm1: PsModuleSchema, PsModuleDefaults,      │
│    PsModuleData, SchemaNode                                │
│  - BuildLog.psm1: BuildLog, BuildSummary, BuildLogEntry,   │
│    BuildTaskResult, TestResult                             │
│  - Enums.psm1: SaveOptions, ModuleItemAttribute            │
│  - defaults/{Script,Binary,Cim,Manifest}/ — templates      │
└────────────────────────┬────────────────────────────────────┘
                         │ uses templates
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Generated module projects                                 │
│  (the PowerShell module that the consumer is authoring)    │
└─────────────────────────────────────────────────────────────┘
```

### Public API Surface

Exposes high-level cmdlets for the full PowerShell module lifecycle — creation, building, testing, and publishing to repositories. Each public function is a thin wrapper that:

- Accepts and validates user input (`CmdletBinding`, `SupportsShouldProcess`, `ValidateScript`, `ValidateSet`, `ValidatePattern`).
- Returns objects to the pipeline (or uses `process`/`end` blocks to maintain state across pipeline stages).
- Instantiates and delegates to a core domain class in `Private/`.

External integrations (GitHub Releases via REST, PowerShell Gallery, dotnet build) are reached through this layer.

### Build Engine & Module Scaffolding

Provides the core orchestration, schema validation, and automated scaffolding for Script, Binary, CIM, and Manifest modules.

- **Core orchestrator** — `Orchestrator.psm1` defines the `BuildOrchestrator` class (extending `PsCraft`) which manages the build lifecycle (`Clean`, `Compile`, `Test`) and dispatches to type-specific compilers (`CompileScriptModule`, `CompileBinaryModule`, etc.).
- **Data & schema layer** — `ModuleData.psm1` implements `PsModuleDefaults` and `PsModuleSchema` to define directory structures and default content templates for each module type, while `PsModuleData` acts as a dictionary-based state container.
- **Logging & diagnostics** — `BuildLog.psm1` provides the `BuildLog` static class for structured console output (using `AnsiConsole` when available) and `BuildSummary` for post-build reporting.
- **Type definitions** — `Enums.psm1` declares shared enumerations (`SaveOptions`, `ModuleItemAttribute`) used across the module's classes.
- **Validation** — `cmdlets/Test-ProjectSchema.ps1` exposes `Test-PsModuleSchema` to validate project structures against the defined `PsModuleSchema`.

### Module Type Templates (`Private/defaults/`)

The `defaults/` folder contains per-type scaffolding templates that decouple generation logic from execution logic:

| Folder | Purpose | Key files |
|---|---|---|
| `defaults/Script/` | Plain PowerShell script modules | `Builder.ps1`, `Tester.ps1`, `ScriptAnalyzer.ps1`, `RootLoader.ps1`, `LocalData.ps1`, `FeatureTest.ps1`, `IntegrationTest.ps1`, `ModuleTest.ps1` |
| `defaults/Binary/` | C#-based binary cmdlet modules | `CmdletClass.cs`, `ProjectFile.csproj`, `ModuleTest.ps1` |
| `defaults/Cim/` | CIM cmdlet definition modules | `CimDefinition.cdxml`, `ModuleTest.ps1` |
| `defaults/Manifest/` | Manifest-only modules | `ModuleTest.ps1` |

The root composition (`PsCraft.psm1`) is the entry point that loads private classes and dot-sources public cmdlets to present a unified surface.


## Public Cmdlets

| Cmdlet | Purpose |
|---|---|
| `Build-Module` | Run the full build pipeline (clean, compile, test, package) for the current module project. |
| `New-PsModule` | Scaffold a new module project of a chosen type (Script, Binary, CIM, Manifest). |
| `Test-Module` | Execute the Pester test suite and analyzer checks. |
| `Publish-PsModule` | Publish the built module to the PowerShell Gallery. |
| `Publish-GitHubRelease` | Create / update a GitHub Release for a tag (uses GitHub REST API v3). |
| `Get-PSGalleryStatus` | Check publishing status of a module on the PowerShell Gallery. |
| `Move-ModulePath` | Move a built module artifact to a target path (commonly into `Modules/` for consumption). |
| `Set-BuildVariables` | Initialize the build environment variables consumed by the orchestrator. |


## Internal Domain Classes

### `Orchestrator.psm1`

Defined in `Private/Orchestrator.psm1`:

- `class AliasVisitor : System.Management.Automation.Language.AstVisitor` — AST walker used for static analysis (e.g. detecting alias usage in code under test).
- `class ParseResult` — Holds the outcome of a script/AST parse.
- `class BuildContext` — Per-build state container passed to compile/test steps.
- `class PsModule : IDisposable` — Represents a single PowerShell module project; owns load/save lifecycle and resource cleanup. **Note:** PsModule derives from `System.Collections.Generic.Dictionary[string, Object]`, not from `IDictionary`/`IEnumerable` — see [Previous Bug Fixes](#previous-bug-fixes) and [Dependencies → PowerShell Class System](#powershell-class-system) for the implications.
- `class PsCraft : Microsoft.PowerShell.Commands.ModuleCmdletBase` — Base domain class; inherits PowerShell cmdlet infrastructure so domain code can write to the standard streams.
- `class BuildOrchestrator : PsCraft` — The end-to-end build coordinator. Detects the module topology and dispatches to the appropriate compile pipeline.

### `ModuleData.psm1`

Defined in `Private/ModuleData.psm1`:

- `class SchemaNode` — Recursive tree node describing a directory or file in a module layout.
- `class PsModuleSchema` — Validates an existing project against an expected `SchemaNode` tree.
- `class PsModuleDefaults` — Static factory / template provider that returns the appropriate `PsModuleSchema` for a given module type.
- `class PsModuleData : System.Collections.Generic.Dictionary[string, Object]` — Dictionary-based state container for arbitrary key/value pairs about a module.

### `BuildLog.psm1`

Defined in `Private/BuildLog.psm1`:

- `class BuildLogEntry` — A single log line / structured event.
- `class BuildTaskResult` — Outcome of a single build task (e.g. compile, test, package).
- `class TestResult` — Pester-style test outcome (passed/failed/skipped, message, stack).
- `static class BuildLog` — Console output helper. Honors `AnsiConsole` availability for color, falls back to plain text otherwise. **All build steps route through this class for consistent formatting.**
- `class BuildSummary` — Aggregates `BuildTaskResult` entries and renders a post-build report.

### `Enums.psm1`

Defined in `Private/Enums.psm1`:

- `enum SaveOptions` — Controls overwrite / conflict behavior when persisting module artifacts.
- `enum ModuleItemAttribute` — Flags describing the kind of file a schema node represents (script, manifest, test, docs, …).


## Supported Module Types

| Type | Description | When to use |
|---|---|---|
| **Script** | Pure PowerShell functions organized in `.ps1` files. Default. | Most PowerShell modules. |
| **Binary** | C#-compiled cmdlet assemblies; includes a `.csproj` and starter `CmdletClass.cs`. | Performance-critical cmdlets, low-level system access, or any case where C# is required. |
| **CIM** | CIM cmdlet definition modules (`.cdxml`). | Modules that wrap CIM classes / WMI providers. |
| **Manifest** | Manifest-only modules (`.psd1` only, no implementation files). | Re-export modules, meta-modules, or modules that simply repackage other modules. |


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


## Dependencies

PsCraft relies on a small set of external and language-level dependencies. The most important ones are documented in this folder.

### Logging — `cliHelper.logger`

A thread-safe, in-memory and file-based logging module for PowerShell. Install from the PowerShell Gallery:

```PowerShell
Install-Module cliHelper.logger
```

Typical usage inside a script or module:

```PowerShell
#Requires -Modules cliHelper.logger

try {
    $logger = [IO.Path]::Combine([IO.Path]::GetTempPath(), "MyAppLogs") | New-Logger
    $logger | Add-JsonAppender
    $logger.LogInfoLine("Application started.")
} finally {
    $logger.ReadEntries(@{ type = "JSON" })
    $logger.Dispose()   # <-- ALWAYS dispose to flush and release file handles
}
```

Full in-depth usage, custom `LogEntry` subclasses, and appender configuration are documented here: [About_logger_module](./about_logger_module_usage.md).

> ⚠️ **Important:** appenders (especially file-based ones) hold resources. You **must** call `$logger.Dispose()` when you are finished logging to ensure logs are flushed and files are closed properly. Use a `try...finally` block to ensure it is always called. Failure to do so can lead to:
> - Log messages not being written to files (still stuck in buffers).
> - File locks being held, preventing other processes (or even later runs of your script) from accessing the log files.

### PowerShell Class System

PsCraft's domain layer is implemented with PowerShell classes (constructors, methods, properties, inheritance, and interfaces). The relevant `about_*` topics are mirrored in this folder:

- [About_Classes_Constructors](./about_Classes_Constructors.md) — How to define constructors, static constructors, base-class invocation, `Init()` chaining pattern (used heavily in PsCraft's `PsModule` family — see [Coding Conventions](#coding-conventions)).
- [About_Classes_Methods](./about_Classes_Methods.md) — Method definitions, static methods, hidden methods, `Update-TypeData` pattern.
- [About_Classes_Properties](./about_Classes_Properties.md) — Property declarations, validation attributes, hidden/static properties, `Update-TypeData` for calculated properties and aliases.
- [About_Classes_Inheritance](./about_Classes_Inheritance.md) — Single inheritance, interface implementation (`IEquatable`, `IComparable`, `IFormattable`), generic-type inheritance, **type accelerators** (used by PsCraft to publish its types without requiring a `using module` statement).

> 💡 **Pitfall to be aware of:** PowerShell classes **do not** implement `IDictionary` / `IEnumerable`. Although `PsModuleData` and `PsModule` inherit from `System.Collections.Generic.Dictionary[string, Object]`, that base class is *not* exposed through a PowerShell-defined class as an enumerator. As a result, calling `.GetEnumerator()` directly on a class instance **fails**. Iterate with `foreach` (which uses the language-level enumeration) or expose an explicit enumerator method, e.g.:
>
> ```powershell
> foreach ($item in $psModuleData) { ... }   # works
> $psModuleData.GetEnumerator()              # throws "GetEnumerator() does not exist"
> ```

### Coding Conventions

- **Public cmdlets** in `Public/` are thin wrappers that instantiate and delegate to core domain classes defined in `Private/`. Domain logic is encapsulated in PowerShell classes (e.g. `PsModule`, `PsCraft`) within `Private/` modules, promoting an object-oriented architecture over pure functional scripting.
- **Class construction** uses a hidden `Init` method called by constructors to centralize initialization logic and avoid code duplication across overloads. This is the workaround for PowerShell's lack of constructor chaining — see [About_Classes_Constructors](./about_Classes_Constructors.md#limitations).
- **Static factory methods** (e.g. `PsModule::Create`, `PsCraft::From`) are preferred over direct constructor calls to handle path resolution and complex setup.
- **Build steps and status messages** are routed through the `BuildLog` static class to ensure consistent formatting and optional ANSI color support.


## CI/CD Integration

PsCraft ships with workflows for both GitHub Actions and Azure Pipelines:

- **GitHub Actions** (`.github/workflows/`):
  - `build_module.yaml` — Build & test on every push / PR.
  - `publish_module.yaml` — Publish to the PowerShell Gallery and create a GitHub Release on tag.
  - `delete_old_workflow_runs.yaml` — Periodic cleanup of old workflow runs.
- **Azure Pipelines** — `azure-pipelines.yml` mirrors the build/test pipeline.
- **Devcontainer** — `.devcontainer/` provides a reproducible containerized dev environment (Dockerfile + `devcontainer.json`).


## Documentation Links

- [About_Modules](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_modules) — Microsoft's official module documentation.
- [About_logger_module](./about_logger_module_usage.md) — Thread-safe logging dependency.
- [About_Classes_Constructors](./about_Classes_Constructors.md) — PowerShell class constructor patterns.
- [About_Classes_Methods](./about_Classes_Methods.md) — PowerShell class method patterns.
- [About_Classes_Properties](./about_Classes_Properties.md) — PowerShell class property patterns.
- [About_Classes_Inheritance](./about_Classes_Inheritance.md) — Inheritance, interfaces, and type accelerators.
- [The Monad Manifesto](https://www.jsnover.com/Docs/MonadManifesto.pdf) — Core PowerShell concepts.


## Community Resources

- [The SysAdmin Channel](https://thesysadminchannel.com/powershell-module/) — Practical module development.
- [Mike F Robbins' Blog](https://mikefrobbins.com/2018/08/17/powershell-script-module-design-public-private-versus-functions-internal-folders-for-functions/) — Module design patterns.
- [PowerShell Modules and Encapsulation](https://www.simple-talk.com/dotnet/.net-tools/further-down-the-rabbit-hole-powershell-modules-and-encapsulation/) — Advanced module concepts.


## Previous Bug Fixes


1. **Critical Bug** — `Type must be a type provided by the runtime (Parameter 'types')`
   > **Root cause** (real one, after bisecting): The `PsModule` class had two overloaded `Equals` methods where one accepted `[PsModule]$other` — the class itself as a parameter type. When PowerShell's `DefaultBinder.SelectMethod()` tries to resolve which overload to compile during type definition, `PsModule` is still an incomplete / not-yet-compiled type at that point, so the runtime throws the "type must be a type provided by the runtime" error.

   **Fix**: Merged both `Equals` overloads into a single `[bool] Equals([object]$other)` that uses `-as [PsModule]` internally. The `IEquatable[PsModule]` interface declaration was also removed (it was the first clue, but not the actual trigger on its own).
