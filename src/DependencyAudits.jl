""" DependencyAudits: Audit Julia project dependencies """

module DependencyAudits

using JuliaSyntax, TOML
using RegistryInstances

export uuidof, registeredversions, latestversion, versionof, packagestrings
export finddependencies, finddependencyuses, auditdependencies, auditreport, reportaudit

"""
    stdlibnames()::Set{Symbol}

Return the set of standard-library module names available in the running
Julia installation. Built by scanning `Sys.STDLIB`. Run once at startup to 
cache the list of standard libraries as a const.
"""
function stdlibnames()::Set{Symbol}
    names = Set{Symbol}()
    if isdir(Sys.STDLIB)

        for entry in readdir(Sys.STDLIB)
            if isdir(joinpath(Sys.STDLIB, entry))
                push!(names, Symbol(entry))
            end
        end

    end
    return names
end

# Cached set of standard-library module names
const STDLIBS = stdlibnames()

const REGISTRY = try
    first(reachable_registries())
catch
    nothing
end
const PACKAGE_ENTRIES = Dict{String,String}()

if !isnothing(REGISTRY)
    for (uuid, names) in REGISTRY
        PACKAGE_ENTRIES[names.name] = string(names.uuid)
    end
end

"""
    uuidof(s::AbstractString)
    uuidof(s)

Return the UUID of the package with the given name `s` as a string. Returns a string
of the uuid if the package is found in the global registry. Note that standard library 
modules such as `Pkg` are not in such global registries, and so will not be found. 
Returns nothing if the registry is not available or the package is not found. 
Other types that can be converted to a string will also work.
"""
uuidof(s::AbstractString) = get(PACKAGE_ENTRIES, s, nothing)
uuidof(s) = uuidof(string(s))

"""
    registeredversions(name; includeremoved=false) -> Vector{VersionNumber}

All versions of package `name` found in the REGISTRY.
"""
function registeredversions(name::AbstractString; includeremoved::Bool=false)
    versions = VersionNumber[]
    for (_, entry) in REGISTRY.pkgs
        if entry.name == name
            info = registry_info(entry)
            for (v, vinfo) in info.version_info
                (includeremoved || !vinfo.yanked) && push!(versions, v)
            end
        end
    end
    return sort!(unique!(versions))
end

"""
    latestversion(name; includeremoved=false) -> Union{VersionNumber, Nothing}

Return the latest version of package `name` found in the REGISTRY, or `nothing` if no 
versions are found. `includeremoved` controls whether removed versions are considered.
Will look up 
"""
function latestversion(name::AbstractString; includeremoved::Bool=false)
    vs = registeredversions(name; includeremoved=includeremoved)
    return isempty(vs) ? nothing : last(vs)
end
latestversion(s) = latestversion(string(s))

"""
    versionof(name) -> Union{VersionNumber, Nothing}

Argument `name` should be String or an objectconvertible to a string.
Return the latest version of package `name` found in the REGISTRY, or `nothing` if no 
versions are found. Alias for `latestversion`.
"""
versionof(name) = latestversion(name)

"""
    packagestrings(pkgname::AbstractString)

Return a named tuple containing name, UUID, and latest version of the 
package `pkgname` found in the global registry, without downloading it.
"""
function packagestrings(pkgname::AbstractString)
    return (name=pkgname, uuid=uuidof(pkgname), version=latestversion(pkgname))
end

"""
    finddependencies(dirpath::AbstractString = ".";
                      exclude = ["test", "docs", "benchmark", ".git"])::Vector{Symbol}

Recursively scan `dirpath` for Julia source files (`.jl`) and return a
sorted vector of the **top-level** module names that appear in `using` /
`import` statements.

Relative imports (those beginning with `.`) are ignored.
Directories listed in `exclude` (matched by basename) are skipped.
"""
function finddependencies(
    dirpath::AbstractString=".";
    exclude=["test", "docs", "benchmark", ".git"],
)
    dependencies = Set{Symbol}()
    base = abspath(dirpath)

    for (root, dirs, files) in walkdir(base)
        # prune excluded directories in-place
        filter!(d -> !(d in exclude), dirs)

        for file in files
            endswith(file, ".jl") || continue
            filepath = joinpath(root, file)
            extract_modules_from_file!(filepath, dependencies)
        end
    end

    return sort!(collect(dependencies))
end

"""
    finddependencyuses(dirpath::AbstractString = ".";
                         exclude = ["test", "docs", "benchmark", ".git"])
        ::Dict{Symbol,Vector{String}}

Recursively scan `dirpath` for Julia source files and return a dictionary
mapping each imported top-level module to the list of files (relative to
`dirpath`) in which it appears.
"""
function finddependencyuses(
    dirpath::AbstractString=".";
    exclude=["test", "docs", "benchmark", ".git"],
)
    uses = Dict{Symbol,Vector{String}}()
    base = abspath(dirpath)

    for (root, dirs, files) in walkdir(base)
        filter!(d -> !(d in exclude), dirs)

        for file in files
            endswith(file, ".jl") || continue
            filepath = joinpath(root, file)
            modules = Set{Symbol}()
            extract_modules_from_file!(filepath, modules)
            relativepath = relpath(filepath, base)

            for mod in modules
                push!(get!(uses, mod, String[]), relativepath)
            end
        end
    end

    for paths in values(uses)
        sort!(paths)
    end

    return uses
end

"""
    auditdependencies(dirpath::AbstractString = ".";
                  projectpath = nothing,
                  exclude = ["test", "docs", "benchmark", ".git"],
                  include_extras::Bool = false,
                  include_weakdeps::Bool = false)::NamedTuple

Compare the modules actually referenced by Julia source files with the
dependencies declared in `Project.toml` (or `JuliaProject.toml`).

# Arguments
- `dirpath` – root of the project tree to scan.
- `projectpath` – explicit path to the project file; when `nothing` the
      function looks for `Project.toml` or `JuliaProject.toml` under `dirpath`.
- `allowmissingtoml` – whether to allow missing Project.toml files (default: `true`).
-    allowmissingtoml::Bool=true,
- `exclude` – directory basenames that are skipped while walking the tree.
- `include_extras` – also treat entries under `[extras]` as declared.
- `include_weakdeps` – also treat entries under `[weakdeps]` as declared.
- `shortenversions` – whether to shorten version numbers in TOML snippet (default: `true`).
# Returns
A named tuple with the fields

| field          | meaning                                         |
|----------------|-------------------------------------------------|
| `projectpath`  | absolute path of the project file that was read |
| `declared`     | sorted vector of declared dependency names      |
| `used`         | sorted vector of modules found in source        |
| `unused`       | declared but never referenced                   |
| `undeclared`   | referenced, neither declared nor a stdlib       |
| `stdlibs`      | referenced standard-library modules             |
| `uses`         | `Dict{Symbol,Vector{String}}` of module → files |
| `tomltext`     | text made from the dependencies vector for use  |
|                | if needed for adding to a `Project.toml` file   |

The function reads, but does not modify the Project.toml file.
"""
function auditdependencies(
    dirpath::AbstractString=".";
    projectpath::Union{Nothing,AbstractString}=nothing,
    allowmissingtoml::Bool=true,
    exclude=["test", "docs", "benchmark", ".git"],
    include_extras::Bool=false,
    include_weakdeps::Bool=false,
    shorten_versions::Bool=true,
)::NamedTuple
    base = abspath(dirpath)

    missingprojectfile = false
    project = begin
        if projectpath === nothing
            candidates = [
                joinpath(base, "Project.toml"),
                joinpath(base, "JuliaProject.toml"),
            ]
            found = findfirst(isfile, candidates)
            if isnothing(found)
                !allowmissingtoml &&
                    throw(ArgumentError(
                        "Neither Project.toml nor JuliaProject.toml found under $base",
                    ))
                missingprojectfile = true
                tmpname = tempname() # dummy Project.toml file
                open(tmpname, "w") do io
                    println(io, "[deps]\n\n[compat]\njulia = \"1\"\n")
                end
                pushfirst!(candidates, tmpname)
                found = 1
            end
            candidates[found]
        else
            abspath(projectpath)
        end
    end

    isfile(project) || throw(ArgumentError("Project file not found: $project"))

    projectdata = try
        TOML.parsefile(project)
    catch err
        throw(ArgumentError("Could not parse $project: $err"))
    end

    declared = Set{Symbol}()
    for section in ("deps",)
        table = get(projectdata, section, Dict{String,Any}())

        for name in keys(table)
            push!(declared, Symbol(name))
        end
    end
    if include_extras
        table = get(projectdata, "extras", Dict{String,Any}())

        for name in keys(table)
            push!(declared, Symbol(name))
        end
    end
    if include_weakdeps
        table = get(projectdata, "weakdeps", Dict{String,Any}())

        for name in keys(table)
            push!(declared, Symbol(name))
        end
    end

    uses = finddependencyuses(base; exclude=exclude)
    used = Set{Symbol}(keys(uses))
    stdlibs_used = intersect(used, STDLIBS)
    unused = setdiff(declared, used)
    missingones = setdiff(used, union(declared, STDLIBS))

    tups = packagestrings.(string.(unique!(vcat(collect(used), collect(declared)))))
    tomltxt = isempty(tups) || !any(!isnothing, getfield.(tups, :uuid)) ?
              "" :
    begin
        deps = join(
            [t.name * " = " * "\"" * t.uuid * "\"" for t in tups if !isnothing(t.uuid)],
            "\n",
        )
        if shorten_versions
            compat = join(
                [
                    t.name * " = " * "\"" * cliplast(t.version) * "\""
                    for t in tups
                    if !isnothing(t.version)
                ],
                "\n",
            )
        else
            compat = join(
                [
                    t.name * " = " * "\"" * string(t.version) * "\""
                    for t in tups
                    if !isnothing(t.version)
                ],
                "\n",
            )
        end
        "[deps]\n" * deps * "\n\n[compat]\njulia = \"1.10\"\n" * compat * "\n"
    end

    return (
        projectpath=missingprojectfile ? "Missing a Project.toml type file" : project,
        declared=sort!(collect(declared)),
        used=sort!(collect(used)),
        unused=sort!(collect(unused)),
        undeclared=sort!(collect(missingones)),
        stdlibs=sort!(collect(stdlibs_used)),
        uses=uses,
        tomltext=tomltxt,
    )
end

"""
    auditreport(audit; io::IO = stdout)

Print a human-readable summary of the result returned by `auditdependencies`.
"""
function auditreport(audit; io::IO=stdout)
    println(io, "Project file : ", audit.projectpath)
    println(io)
    println(io, "Declared dependencies ($(length(audit.declared))):")
    if isempty(audit.declared)
        println(io, "  (none)")
    else
        foreach(d -> println(io, "  ", d), audit.declared)
    end

    println(io)
    println(io, "Used modules ($(length(audit.used))):")
    if isempty(audit.used)
        println(io, "  (none)")
    else
        foreach(u -> println(io, "  ", u), audit.used)
    end

    println(io)
    if !isempty(audit.unused)
        println(io, "⚠  Unused declared dependencies:")
        foreach(u -> println(io, "  ", u), audit.unused)
    else
        println(io, "✓  No unused declared dependencies")
    end

    println(io)
    if !isempty(audit.undeclared)
        println(io, "⚠  Missing from Project.toml (not stdlib):")
        foreach(m -> println(io, "  ", m), audit.undeclared)
    else
        println(io, "✓  No missing dependencies")
    end

    println(io)
    if !isempty(audit.stdlibs)
        println(io, "Standard libraries used:")
        foreach(s -> println(io, "  ", s), audit.stdlibs)
    end

    println(io)
    println(
        io,
        "Partial suggested possible TOML snippet for dependencies and compatibility:",
    )
    println(io, audit.tomltext)

    return nothing
end

"""
`reportaudit` is an alias for `auditreport`.
"""
const reportaudit = auditreport # alias


"""
    extract_modules_from_file!(filepath, modules::Set{Symbol})

Parse a Julia source file and add every top-level module name that appears
in a `using` or `import` statement to `modules`.
"""
function extract_modules_from_file!(filepath::AbstractString, modules::Set{Symbol})
    code = try
        read(filepath, String)
    catch err
        @warn "Could not read $filepath" exception = err
        return
    end

    expr = try
        parseall(Expr, code)
    catch err
        @warn "Syntax error while parsing $filepath" exception = err
        return
    end

    extract_from_expr!(expr, modules)
    return nothing
end

"""
    extract_from_expr!(ex, modules::Set{Symbol})

Walk an `Expr` produced by JuliaSyntax / Base and collect top-level module
names from `using` / `import` statements.
"""
function extract_from_expr!(ex, modules::Set{Symbol})
    if !(ex isa Expr)
        return
    end

    if ex.head === :using || ex.head === :import
        for arg in ex.args
            add_toplevel_module!(arg, modules)
        end
        return # quit recursive descent
    end

    # Recurse into all other expression forms (including :toplevel, :module, :block …)
    for arg in ex.args
        extract_from_expr!(arg, modules)
    end
    return nothing
end

"""
    add_toplevel_module!(arg, modules::Set{Symbol})

Extract the single top-level module name from one argument of a `using` /
`import` expression.  Relative imports (leading dots) are ignored.
"""
function add_toplevel_module!(arg, modules::Set{Symbol})
    if arg isa Symbol
        # plain `using Foo`
        push!(modules, arg)
        return
    end

    if !(arg isa Expr)
        return
    end

    # `using Foo: bar`  →  Expr(:(:), Expr(:., :Foo), …)
    if arg.head === :(:)
        add_toplevel_module!(arg.args[1], modules)
        return
    end

    # `import Foo as Bar`  →  Expr(:as, Expr(:., :Foo), :Bar)
    if arg.head === :as
        add_toplevel_module!(arg.args[1], modules)
        return
    end

    # Dotted path:  Expr(:., :A, :B, :C)   or   Expr(:., :., :A)  (relative)
    if arg.head === :.
        # Walk to the left-most identifier, skipping pure-dot markers
        node = arg
        while node isa Expr && node.head === :. && !isempty(node.args)
            first = node.args[1]
            if first === :. || (first isa Expr && first.head === :.)
                # relative import – ignore the whole path
                return
            end
            if first isa Symbol
                push!(modules, first)
                return
            end
            node = first
        end
    end
    return nothing
end

"""
    cliplast(s::AbstractString)::String

Remove the last dot-separated component from a string, if it has two or more components.
"""
function cliplast(s::AbstractString)::String
    return count(==('.'), s) < 2 ? s : replace(s, r"\.[^.]*$" => "")
end
cliplast(v::VersionNumber) = cliplast(string(v))


end # module DependencyAudits
