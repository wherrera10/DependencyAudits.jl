# DependencyAudits.jl

[![Documentation Status](https://img.shields.io/badge/docs-latest-blue.svg)](https://wherrera10.github.io/DependencyAudits.jl/)

<img src="https://github.com/wherrera10/DependencyAudits.jl/blob/main/docs/src/assets/depaud.png">

Audit source code dependencies for the correctness of the files listed in Project.toml.
Useful to assist in creating a Project.toml for an existing code, since ``reportaudit`` will
suggest lines to be placed in Project.toml and report packages used but not included in your .toml file.

Example: 

## Example:

    julia> using DependencyAudits

    julia> cd("my code directory")

    julia> audit = auditdependencies()

    julia> auditreport(audit)
  
