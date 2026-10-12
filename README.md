# DependencyAudits.jl

[![Documentation Status](https://img.shields.io/badge/docs-latest-blue.svg)](https://wherrera10.github.io/DependencyAudits.jl/)

<img src="https://github.com/wherrera10/DependencyAudits.jl/blob/main/docs/src/assets/depaud.png">

Audit source code dependencies for the correctness of the files listed in Project.toml.
Useful to assist in creating a Project.toml for an existing code tree. 
`auditreport(auditdependencies())` will suggest lines to be placed in Project.toml 
and report packages used but not included in your .toml file. By default this 
audit will proceed even if a .toml file has not yet been created, which can
be useful when starting from Julia code being made into a distributable package.

## Example:

    julia> using DependencyAudits

    julia> cd("my code directory")

    julia> audit = auditdependencies()

    julia> auditreport(audit)
  
