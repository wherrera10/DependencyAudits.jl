# DependencyAudits.jl

[![Documentation Status](https://img.shields.io/badge/docs-latest-blue.svg)](https://wherrera10.github.io/DependencyAudits.jl/)

<img src="https://github.com/wherrera10/DependencyAudits.jl/blob/main/docs/src/assets/depaud.png">

Audit source code dependencies

Example: 

## Example:

    julia> using DependencyAudits

    julia> cd("my code directory")

    julia> audit = auditdependencies()

    julia> auditreport(audit)
  
