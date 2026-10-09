""" DependencyAudits: Audit Julia project dependencies """

module DependencyAudits

using JuliaSyntax, TOML
using RegistryInstances

export uuidof, registeredversions, latestversion, versionof, packagestrings
export finddependencies, finddependencyuses, auditdependencies, auditreport, reportaudit

"""
    stdlibnames()::Set{Symbol}

Return the set of non-jll standard-library module names available in the running
Julia installation. Built by scanning `Sys.STDLIB`.
"""
function stdlibnames()::Set{Symbol}
    names = Set{Symbol}([:Base, :Core])
    if isdir(Sys.STDLIB)
        for entry in readdir(Sys.STDLIB)
            if !endswith(entry, "_jll") && isdir(joinpath(Sys.STDLIB, entry))
                push!(names, Symbol(entry))
            end
        end
    end
    return names
end

const STDLIBS = stdlibnames()

const REGISTRY = try
    first(reachable_registries())
catch
    nothing
end

const PACKAGE_ENTRIES = Dict{String,String}()

if !isnothing(REGISTRY)
    for (_, entry) in REGISTRY
        PACKAGE_ENTRIES[entry.name] = string(entry.uuid)
    end
end

"""
    uuidof(s::AbstractString)
    uuidof(s)

Return the UUID of the package with the given name `s` as a string.
Returns `nothing` if the registry is unavailable or the package is not found.
"""
uuidof(s::AbstractString) = get(PACKAGE_ENTRIES, s, nothing)
uuidof(s) = uuidof(string(s))

"""
    registeredversions(name; includeremoved=false) -> Vector{VersionNumber}

Return all versions of package `name` found in the reachable registry.
"""
function registeredversions(name::AbstractString; includeremoved::Bool=false)
    versions = VersionNumber[]
    isnothing(REGISTRY) && return versions
    for (_, entry) in REGISTRY
        entry.name == name || continue
        info = registry_info(entry)
        for (v, vinfo) in info.version_info
            (includeremoved || !vinfo.yanked) && push!(versions, v)
        end
    end
    return sort!(unique!(versions))
end

"""
    registeredversions(name; kwargs...) -> Vector{VersionNumber}

Alias for `registeredversions` that accepts any type convertible to a string.
"""
registeredversions(name; kwargs...) = registeredversions(string(name); kwargs...)

"""
    latestversion(name; includeremoved=false) -> Union{VersionNumber, Nothing}

Return the latest registered version of package `name`, or `nothing` if no
version is available.
"""
function latestversion(name::AbstractString; includeremoved::Bool=false)
    vs = registeredversions(name; includeremoved=includeremoved)
    return isempty(vs) ? nothing : last(vs)
end

"""
    latestversion(s; kwargs...) -> Union{VersionNumber, Nothing}

Alias for `latestversion` that accepts any type convertible to a string.
"""
latestversion(s; kwargs...) = latestversion(string(s); kwargs...)

"""
    versionof(name) -> Union{VersionNumber, Nothing}

Alias for `latestversion`.
"""
versionof(name) = latestversion(name)

"""
    packagestrings(pkgname::AbstractString)

Return a named tuple containing the package name, UUID, and latest registered
version without downloading the package.
"""
function packagestrings(pkgname::AbstractString)
    return (name=pkgname, uuid=uuidof(pkgname), version=latestversion(pkgname))
end

"""
    _stdlib_uuid(name) -> Union{String, Nothing}

Get the UUID of a standard library, read from its Project.toml under `Sys.STDLIB`.
"""
function _stdlib_uuid(name)
    file = joinpath(Sys.STDLIB, string(name), "Project.toml")
    isfile(file) || return nothing
    uuid = get(TOML.parsefile(file), "uuid", nothing)
    return uuid isa AbstractString ? String(uuid) : nothing
end

const DEFAULT_EXCLUDE = ["test", "docs", "benchmark", "example", ".git"]

"""
    finddependencies(dirpath::AbstractString = ".";
                     exclude = DEFAULT_EXCLUDE)::Vector{Symbol}

Recursively scan `dirpath` for Julia source files and return a sorted vector of
the top-level module names appearing in `using` or `import` statements.

Relative imports are ignored. Directories listed in `exclude` are skipped by
basename.
"""
function finddependencies(
    dirpath::AbstractString=".";
    exclude=DEFAULT_EXCLUDE,
)
    dependencies = Set{Symbol}()
    base = abspath(dirpath)
    for (root, dirs, files) in walkdir(base)
        filter!(d -> !(d in exclude), dirs)
        for file in files
            endswith(file, ".jl") || continue
            extract_modules_from_file!(joinpath(root, file), dependencies)
        end
    end
    delete!(dependencies, Symbol("Main")) # Remove the Main module if present
    return sort!(collect(dependencies))
end

"""
    finddependencyuses(dirpath::AbstractString = ".";
                       exclude = DEFAULT_EXCLUDE)
        ::Dict{Symbol,Vector{String}}

Recursively scan `dirpath` for Julia source files and return a dictionary
mapping each imported top-level module to the list of files, relative to
`dirpath`, in which it appears.
"""
function finddependencyuses(
    dirpath::AbstractString=".";
    exclude=DEFAULT_EXCLUDE,
)
    uses, _ = _finddependencyuses(dirpath; exclude=exclude)
    return uses
end

"""
    _finddependencyuses(dirpath::AbstractString; exclude)::Tuple{Dict{Symbol,Vector{String}}, Vector{String}}

Recursively scan via `walkdir` the `dirpath` for Julia source files and return a 
Tuple{Dict{Symbol,Vector{String}}, Vector{String}} containing:

- A dictionary mapping each imported top-level module to the list of files, relative to `dirpath`, in which it appears.
- A vector of parse errors encountered during the scan, used to guide the parsing of files in subsequent calls.
"""
function _finddependencyuses(
    dirpath::AbstractString;
    exclude,
)
    uses = Dict{Symbol,Vector{String}}()
    parse_errors = String[]
    base = abspath(dirpath)
    for (root, dirs, files) in walkdir(base)
        filter!(d -> !(d in exclude), dirs)
        for file in files
            endswith(file, ".jl") || continue
            filepath = joinpath(root, file)
            modules = Set{Symbol}()
            extract_modules_from_file!(
                filepath,
                modules;
                parse_errors=parse_errors,
            )
            relativepath = relpath(filepath, base)
            for mod in modules
                push!(get!(uses, mod, String[]), relativepath)
            end
        end
    end
    for paths in values(uses)
        sort!(paths)
    end
    return uses, parse_errors
end

"""
    auditdependencies(dirpath::AbstractString = ".";
                      projectpath = nothing,
                      allowmissingtoml = true,
                      exclude = DEFAULT_EXCLUDE,
                      include_extras = false,
                      include_weakdeps = false,
                      shorten_versions = true)::NamedTuple

Compare modules referenced by Julia source files with dependencies declared in
`Project.toml` or `JuliaProject.toml`.

`projectpath` specifies an explicit project file. If it is `nothing`, the
function searches under `dirpath`.

`allowmissingtoml` controls whether a missing project file is permitted.
`include_extras` and `include_weakdeps` cause `[extras]` and `[weakdeps]`
entries to be included when determining declared dependencies.

`shorten_versions` indicates whether version numbers with 3 or more components in the 
suggested TOML snippet should be shortened by dropping the final integer component.

The returned named tuple contains:

- `projectpath`  – absolute project-file path, or `nothing`
- `projectmissing` – whether no project file was found
- `declared`     – declared dependency names
- `used`         – modules found in source
- `unused`       – declared but never referenced
- `undeclared`   – referenced modules that are neither declared nor stdlibs
- `stdlibs`      – referenced standard-library modules
- `uses`         – module → files mapping
- `parse_errors` – files that could not be parsed
- `tomltext`     – suggested TOML dependency/compatibility snippet

The function reads, but does not modify, the project file.
"""
function auditdependencies(
    dirpath::AbstractString=".";
    projectpath::Union{Nothing,AbstractString}=nothing,
    allowmissingtoml::Bool=true,
    exclude=DEFAULT_EXCLUDE,
    include_extras::Bool=false,
    include_weakdeps::Bool=false,
    shorten_versions::Bool=true,
)::NamedTuple
    base = abspath(dirpath)
    projectmissing = false

    project = if projectpath === nothing
        candidates = (
            joinpath(base, "Project.toml"),
            joinpath(base, "JuliaProject.toml"),
        )
        found = findfirst(isfile, candidates)
        if isnothing(found)
            if !allowmissingtoml
                throw(ArgumentError(
                    "Neither Project.toml nor JuliaProject.toml found under $base"
                ))
            end
            projectmissing = true
            nothing
        else
            candidates[found]
        end
    else
        abspath(projectpath)
    end

    if projectmissing
        projectdata = Dict{String,Any}("deps" => Dict{String,Any}())
    else
        isfile(project) || throw(ArgumentError("Project file not found: $project"))
        projectdata = try
            TOML.parsefile(project)
        catch err
            throw(ArgumentError("Could not parse $project: $err"))
        end
    end

    declared = Set{Symbol}()

    for name in keys(get(projectdata, "deps", Dict{String,Any}()))
        push!(declared, Symbol(name))
    end

    if include_extras
        for name in keys(get(projectdata, "extras", Dict{String,Any}()))
            push!(declared, Symbol(name))
        end
    end

    if include_weakdeps
        for name in keys(get(projectdata, "weakdeps", Dict{String,Any}()))
            push!(declared, Symbol(name))
        end
    end

    uses, parse_errors = _finddependencyuses(base; exclude=exclude)
    used = Set{Symbol}(keys(uses))
    delete!(used, :Base) # ignore references to Base
    delete!(used, :Main) # ignore references to Main
    delete!(used, :.) # ignore references to the current module
    stdlibs_used = intersect(used, STDLIBS)
    unused = setdiff(declared, used)
    undeclared = setdiff(used, union(declared, STDLIBS))

    names = unique!(vcat(collect(used), collect(declared)))
    tups = packagestrings.(string.(names))
    registry_tups = filter(
        t -> !isnothing(t.uuid) && !(Symbol(t.name) in STDLIBS),
        tups,
    )
    stdlib_entries = Tuple{String,String}[]
    for s in sort!(collect(stdlibs_used))
        uuid = _stdlib_uuid(s)
        isnothing(uuid) || push!(stdlib_entries, (string(s), uuid))
    end

    tomltxt = if isempty(registry_tups) && isempty(stdlib_entries)
        ""
    else
        depentries = sort!(vcat(
            [(t.name, t.uuid) for t in registry_tups],
            stdlib_entries,
        ))
        deps = join(["$n = \"$u\"" for (n, u) in depentries], "\n")
        versions = filter(t -> !isnothing(t.version), registry_tups)
        complines = String[
            t.name * " = \"" *
            (shorten_versions ? cliplast(t.version) : string(t.version)) * "\""
            for t in versions
        ]
        append!(complines, ["$n = \"1\"" for (n, _) in stdlib_entries])
        compat = isempty(complines) ? "" : join(complines, "\n") * "\n"
        "[deps]\n" * deps * "\n\n[compat]\njulia = \"1.10\"\n" * compat
    end

    return (
        projectpath=project,
        projectmissing=projectmissing,
        declared=sort!(collect(declared)),
        used=sort!(collect(used)),
        unused=sort!(collect(unused)),
        undeclared=sort!(collect(undeclared)),
        stdlibs=sort!(collect(stdlibs_used)),
        uses=uses,
        parse_errors=parse_errors,
        tomltext=tomltxt,
    )
end

"""
    auditreport(audit; io::IO = stdout)

Print a human-readable summary of the result returned by `auditdependencies`.
"""
function auditreport(audit; io::IO=stdout)
    println(io, "Project file : ", isnothing(audit.projectpath) ? "(none)" : audit.projectpath)

    if audit.projectmissing
        println(io, "⚠  No Project.toml or JuliaProject.toml was found")
    end

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

    if !isempty(audit.stdlibs)
        println(io)
        println(io, "Standard libraries used:")
        foreach(s -> println(io, "  ", s), audit.stdlibs)
    end

    if !isempty(audit.parse_errors)
        println(io)
        println(io, "⚠  Files with syntax/read errors:")
        foreach(path -> println(io, "  ", path), audit.parse_errors)
    end

    println(io)
    println(io, "Suggested possible TOML snippet:")
    println(io, audit.tomltext)

    return nothing
end

"""
    reportaudit

Alias for `auditreport`.
"""
const reportaudit = auditreport

"""
    extract_modules_from_file!(filepath, modules::Set{Symbol})

Parse a Julia source file and add top-level module names appearing in `using`
or `import` statements to `modules`.
"""
function extract_modules_from_file!(
    filepath::AbstractString,
    modules::Set{Symbol};
    parse_errors::Union{Nothing,Vector{String}}=nothing,
)
    code = try
        read(filepath, String)
    catch err
        @warn "Could not read $filepath" exception=err
        parse_errors !== nothing && push!(parse_errors, filepath)
        return
    end

    expr = try
        parseall(Expr, code)
    catch err
        @warn "Syntax error while parsing $filepath" exception=err
        parse_errors !== nothing && push!(parse_errors, filepath)
        return
    end

    extract_from_expr!(expr, modules)
    return nothing
end

"""
    extract_from_expr!(ex, modules::Set{Symbol})

Walk an Expr produced by JuliaSyntax and collect top-level module names from
`using` and `import` statements.
"""
function extract_from_expr!(ex, modules::Set{Symbol})
    ex isa Expr || return

    if ex.head === :using || ex.head === :import
        for arg in ex.args
            add_toplevel_module!(arg, modules)
        end
        return
    end

    for arg in ex.args
        extract_from_expr!(arg, modules)
    end
    return nothing
end

"""
    add_toplevel_module!(arg, modules::Set{Symbol})

Extract the top-level module name from one argument of a `using` or `import`
expression. Relative imports beginning with `.` are ignored.
"""
function add_toplevel_module!(arg, modules::Set{Symbol})
    arg isa Symbol && return push!(modules, arg)
    arg isa Expr || return nothing

    # Process `using Foo: bar` / `import Foo: bar`
    if arg.head === :(:)
        isempty(arg.args) || add_toplevel_module!(arg.args[1], modules)
        return nothing
    end

    # Process `import Foo as Bar`
    if arg.head === :as
        isempty(arg.args) || add_toplevel_module!(arg.args[1], modules)
        return nothing
    end

    # Only need the topmost absolute module name.
    if arg.head === :.
        isempty(arg.args) && return nothing

        firstarg = arg.args[1]

        # Dotted expression whose first component is a dotted expression
        if firstarg isa Expr && firstarg.head === :.
            return nothing
        end

        # `Foo.Bar` / `Foo.Bar.Baz`
        if firstarg isa Symbol
            push!(modules, firstarg)
            return nothing
        end

        return nothing
    end

    return nothing
end

"""
    cliplast(s::AbstractString)::String

Remove the last dot-separated component from a string if it has two or more
components.
"""
function cliplast(s::AbstractString)::String
    return count(==('.'), s) < 2 ? s : replace(s, r"\.[^.]*$" => "")
end

cliplast(v::VersionNumber) = cliplast(string(v))


end # module DependencyAudits
