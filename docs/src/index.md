# DependencyAudits.jl

![Description](assets/depaud.png)

Audit a code tree for its dependencies and correlate with its Project.toml file

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
