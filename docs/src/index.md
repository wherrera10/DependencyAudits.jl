# DependencyAudits.jl

![Description](assets/depaud.png)


Audit source code dependencies for the correctness of the files listed in Project.toml.
Useful to assist in creating a Project.toml for an existing code, since ``reportaudit`` will
suggest lines to be placed in Project.toml and report packages used but not included in your .toml file.


Example:

julia> using DependencyAudits

julia> cd("my code directory")

julia> audit = auditdependencies()

julia> auditreport(audit)

## Functions Reference

```@index
```

```@autodocs

Modules = [DependencyAudits]
```
