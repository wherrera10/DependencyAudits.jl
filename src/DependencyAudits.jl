module DependencyAudits

using JuliaSyntax
using JuliaSyntax: parseall, kind, children, source, GreenNode, K
using TOML

export find_dependencies, find_dependency_uses, audit_project, report

# ---------------------------------------------------------------------------
# Standard libraries (dynamic)
# ---------------------------------------------------------------------------

"""
    stdlib_names() -> Set{Symbol}

Return the set of standard-library module names available in the running
Julia installation.  Built by scanning `Sys.STDLIB`.
"""
function stdlib_names()::Set{Symbol}
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

const STDLIBS = stdlib_names()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    find_dependencies(dir_path::AbstractString = ".";
                      exclude = ["test", "docs", "benchmark", ".git"]) -> Vector{Symbol}

Recursively scan `dir_path` for Julia source files (`.jl`) and return a
sorted vector of the **top-level** module names that appear in `using` /
`import` statements.

Relative imports (those beginning with `.`) are ignored.
Directories listed in `exclude` (matched by basename) are skipped.
"""
function find_dependencies(dir_path::AbstractString = ".";
                           exclude = ["test", "docs", "benchmark", ".git"])
    dependencies = Set{Symbol}()
    base = abspath(dir_path)

    for (root, dirs, files) in walkdir(base)
        # prune excluded directories in-place
        filter!(d -> !(d in exclude), dirs)

        for file in files
            endswith(file, ".jl") || continue
            file_path = joinpath(root, file)
            extract_modules_from_file!(file_path, dependencies)
        end
    end

    return sort!(collect(dependencies))
end

"""
    find_dependency_uses(dir_path::AbstractString = ".";
                         exclude = ["test", "docs", "benchmark", ".git"])
        -> Dict{Symbol,Vector{String}}

Recursively scan `dir_path` for Julia source files and return a dictionary
mapping each imported top-level module to the list of files (relative to
`dir_path`) in which it appears.
"""
function find_dependency_uses(dir_path::AbstractString = ".";
                              exclude = ["test", "docs", "benchmark", ".git"])
    uses = Dict{Symbol, Vector{String}}()
    base = abspath(dir_path)

    for (root, dirs, files) in walkdir(base)
        filter!(d -> !(d in exclude), dirs)

        for file in files
            endswith(file, ".jl") || continue
            file_path = joinpath(root, file)
            modules = Set{Symbol}()
            extract_modules_from_file!(file_path, modules)
            relative_path = relpath(file_path, base)
            for mod in modules
                push!(get!(uses, mod, String[]), relative_path)
            end
        end
    end

    for paths in values(uses)
        sort!(paths)
    end

    return uses
end

"""
    audit_project(dir_path::AbstractString = ".";
                  project_path = nothing,
                  exclude = ["test", "docs", "benchmark", ".git"],
                  include_extras::Bool = false,
                  include_weakdeps::Bool = false)

Compare the modules actually referenced by Julia source files with the
dependencies declared in `Project.toml` (or `JuliaProject.toml`).

# Arguments
- `dir_path` – root of the project tree to scan.
- `project_path` – explicit path to the project file; when `nothing` the
  function looks for `Project.toml` or `JuliaProject.toml` under `dir_path`.
- `exclude` – directory basenames that are skipped while walking the tree.
- `include_extras` – also treat entries under `[extras]` as declared.
- `include_weakdeps` – also treat entries under `[weakdeps]` as declared.

# Returns
A named tuple with the fields

| field          | meaning |
|----------------|---------|
| `project_path` | absolute path of the project file that was read |
| `declared`     | sorted vector of declared dependency names |
| `used`         | sorted vector of modules found in source |
| `unused`       | declared but never referenced |
| `missing`      | referenced, neither declared nor a stdlib |
| `stdlibs`      | referenced standard-library modules |
| `uses`         | `Dict{Symbol,Vector{String}}` of module → files |

The function never modifies the project file.
"""
function audit_project(dir_path::AbstractString = ".";
                       project_path::Union{Nothing,AbstractString} = nothing,
                       exclude = ["test", "docs", "benchmark", ".git"],
                       include_extras::Bool = false,
                       include_weakdeps::Bool = false)
    base = abspath(dir_path)

    project = if project_path === nothing
        candidates = (joinpath(base, "Project.toml"),
                      joinpath(base, "JuliaProject.toml"))
        found = findfirst(isfile, candidates)
        found === nothing && throw(ArgumentError(
            "Neither Project.toml nor JuliaProject.toml found under $base"))
        candidates[found]
    else
        abspath(project_path)
    end

    isfile(project) || throw(ArgumentError("Project file not found: $project"))

    project_data = try
        TOML.parsefile(project)
    catch err
        throw(ArgumentError("Could not parse $project: $err"))
    end

    declared = Set{Symbol}()
    for section in ("deps",)
        table = get(project_data, section, Dict{String,Any}())
        for name in keys(table)
            push!(declared, Symbol(name))
        end
    end
    if include_extras
        table = get(project_data, "extras", Dict{String,Any}())
        for name in keys(table)
            push!(declared, Symbol(name))
        end
    end
    if include_weakdeps
        table = get(project_data, "weakdeps", Dict{String,Any}())
        for name in keys(table)
            push!(declared, Symbol(name))
        end
    end

    uses = find_dependency_uses(base; exclude=exclude)
    used = Set{Symbol}(keys(uses))
    stdlibs_used = intersect(used, STDLIBS)
    unused = setdiff(declared, used)
    missing = setdiff(used, union(declared, STDLIBS))

    return (
        project_path = project,
        declared     = sort!(collect(declared)),
        used         = sort!(collect(used)),
        unused       = sort!(collect(unused)),
        missing      = sort!(collect(missing)),
        stdlibs      = sort!(collect(stdlibs_used)),
        uses         = uses,
    )
end

"""
    report(audit; io::IO = stdout)

Print a human-readable summary of the result returned by `audit_project`.
"""
function report(audit; io::IO = stdout)
    println(io, "Project file : ", audit.project_path)
    println(io)
    println(io, "Declared dependencies ($(length(audit.declared))):")
    isempty(audit.declared) ? println(io, "  (none)") :
        foreach(d -> println(io, "  ", d), audit.declared)

    println(io)
    println(io, "Used modules ($(length(audit.used))):")
    isempty(audit.used) ? println(io, "  (none)") :
        foreach(u -> println(io, "  ", u), audit.used)

    println(io)
    if !isempty(audit.unused)
        println(io, "⚠  Unused declared dependencies:")
        foreach(u -> println(io, "  ", u), audit.unused)
    else
        println(io, "✓  No unused declared dependencies")
    end

    println(io)
    if !isempty(audit.missing)
        println(io, "⚠  Missing from Project.toml (not stdlib):")
        foreach(m -> println(io, "  ", m), audit.missing)
    else
        println(io, "✓  No missing dependencies")
    end

    println(io)
    if !isempty(audit.stdlibs)
        println(io, "Standard libraries used:")
        foreach(s -> println(io, "  ", s), audit.stdlibs)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

"""
    extract_modules_from_file!(file_path, modules::Set{Symbol})

Parse a Julia source file and add every top-level module name that appears
in a `using` or `import` statement to `modules`.
"""
function extract_modules_from_file!(file_path::AbstractString, modules::Set{Symbol})
    code = try
        read(file_path, String)
    catch err
        @warn "Could not read $file_path" exception=err
        return
    end

    # Prefer the Expr AST – it is stable and easy to walk.
    expr = try
        parseall(Expr, code)
    catch err
        @warn "Syntax error while parsing $file_path" exception=err
        return
    end

    extract_from_expr!(expr, modules)
    return nothing
end

"""
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
        return          # do not descend further into the import statement
    end

    # Recurse into all other expression forms (including :toplevel, :module, :block …)
    for arg in ex.args
        extract_from_expr!(arg, modules)
    end
    return nothing
end

"""
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


end # module DependencyAudits
