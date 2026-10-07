module DependencyAudits

using TOML

export find_dependencies, find_dependency_uses, audit_project

const STDLIBS = Set([
    :ArgTools,
    :Artifacts,
    :Base64,
    :CRC32c,
    :Dates,
    :DelimitedFiles,
    :Distributed,
    :Downloads,
    :FileWatching,
    :Future,
    :InteractiveUtils,
    :JuliaSyntax,
    :LibGit2,
    :Libdl,
    :LinearAlgebra,
    :Logging,
    :Markdown,
    :Mmap,
    :NetworkOptions,
    :Pkg,
    :Printf,
    :Profile,
    :REPL,
    :Random,
    :SHA,
    :Serialization,
    :SharedArrays,
    :Sockets,
    :SparseArrays,
    :Statistics,
    :SuiteSparse,
    :TOML,
    :Tar,
    :Test,
    :UUIDs,
    :Unicode,
])

"""
find_dependencies(dir_path::String=".")

Recursively scan `dir_path` for Julia source files and return a sorted
vector of module names (as Symbol) used by `using` and `import` statements.

Only the top-level module name is returned. For example,
"""
function find_dependencies(dir_path::String = ".")
    dependencies = Set{Symbol}()

    for (root, _, files) in walkdir(dir_path)
        for file in files
            if endswith(file, ".jl")
                extract_modules_from_file!(joinpath(root, file), dependencies)
            end
        end
    end

    return sort!(collect(dependencies))
end

"""
    find_dependency_uses(dir_path::String=".")::Dict{Symbol,Vector{String}}

Recursively scan `dir_path` for Julia source files and return a dictionary
mapping each imported module to the files in which it is used.

Paths are relative to `dir_path`.
"""
function find_dependency_uses(dir_path::String = ".")
    uses = Dict{Symbol, Vector{String}}()
    base = abspath(dir_path)

    for (root, _, files) in walkdir(base)
        for file in files
            if endswith(file, ".jl")
                file_path = joinpath(root, file)
                modules = Set{Symbol}()
                extract_modules_from_file!(file_path, modules)
                relative_path = relpath(file_path, base)
                for mod in modules
                    push!(get!(uses, mod, String[]), relative_path)
                end
            end
        end
    end

    for paths in values(uses)
        sort!(paths)
    end

    return uses
end

"""
    audit_project(dir_path::String="."; project_path=nothing)

Compare dependencies actually used by Julia source files with the
dependencies declared in `Project.toml`.

If `project_path` is omitted, `Project.toml` is searched for at the root
of `dir_path`.

Returns a named tuple containing:

project_path
declared
used
unused
missing
stdlibs
uses

where:

* `declared` is the set of dependencies in `[deps]`.
* `used` is the set of modules found in Julia source files.
* `unused` is declared dependencies not found in the source.
* `missing` is non-standard-library modules used by the source but absent
  from `[deps]`.
* `stdlibs` is the set of standard-library modules used by the source.
* `uses` maps each used module to the files in which it occurs.

The function does not modify `Project.toml`.
"""
function audit_project(dir_path::String = "."; project_path::Union{Nothing, String} = nothing)
    base = abspath(dir_path)
    project = if project_path === nothing
        joinpath(base, "Project.toml")
    else
        abspath(project_path)
    end

    !isfile(project) && throw(ArgumentError("Project.toml not found: $project"))

    project_data = try
        TOML.parsefile(project)
    catch err
        throw(ArgumentError("Could not parse Project.toml $project: $err"))
    end

    deps_table = get(project_data, "deps", Dict{String, Any}())
    declared = Set{Symbol}(Symbol(name) for name in keys(deps_table))
    uses = find_dependency_uses(base)
    used = Set{Symbol}(keys(uses))
    stdlibs = intersect(used, STDLIBS)
    unused = setdiff(declared, used)
    missing = setdiff(used, union(declared, STDLIBS))

    return (
        project_path = project,
        declared = sort!(collect(declared)),
        used = sort!(collect(used)),
        unused = sort!(collect(unused)),
        missing = sort!(collect(missing)),
        stdlibs = sort!(collect(stdlibs)),
        uses = uses,
    )

end

"""
    extract_modules_from_file!(file_path, modules)

Parse one Julia source file and add modules found in `using` and `import`
statements to `modules`.
"""
function extract_modules_from_file!(file_path::String, modules::Set{Symbol})
    code = try
        read(file_path, String)
    catch err
        @warn "Could not read $file_path: $err"
        return
    end

    ast = try
        Meta.parseall(code)
    catch err
        @warn "Syntax error parsing $file_path: $err"
        return
    end

    traverse_ast!(ast, modules)
end

"""
    traverse_ast!(expr, modules)

Recursively inspect a Julia expression for `using` and `import`
statements.
"""
function traverse_ast!(expr::Expr, modules::Set{Symbol})
    if expr.head === :using || expr.head === :import
        for arg in expr.args
            mod_name = extract_module_name(arg)
            if mod_name !== nothing
                push!(modules, mod_name)
            end
        end
        return
    end

    for arg in expr.args
        if arg isa Expr
            traverse_ast!(arg, modules)
        end
    end

end

""" null AST if no chance of import or using because no expression involved """
traverse_ast!(::Any, ::Set{Symbol}) = nothing

"""
    extract_module_name(arg)

Extract the top-level module name from an AST node representing a
`using` or `import` argument.
"""
function extract_module_name(arg)
    if arg isa Symbol
        # Ignore relative imports such as `import .Foo`.
        return arg === :(.) ? nothing : arg
    end

    if !(arg isa Expr)
        return nothing
    end

    if arg.head === :.
        # Foo.Bar
        if !isempty(arg.args) && arg.args[1] isa Symbol
            return arg.args[1]
        end
    elseif arg.head === :as
        # Foo as F
        return extract_module_name(arg.args[1])
    elseif arg.head === :(::)
        return extract_module_name(arg.args[1])
    elseif arg.head === :colon
        # Foo: bar, baz
        return isempty(arg.args) ? nothing : extract_module_name(arg.args[1])
    elseif arg.head === Symbol(":")
        # Compatibility with alternate parser representations.
        return isempty(arg.args) ? nothing : extract_module_name(arg.args[1])
    end

    return nothing
end


end # module DependencyAudits
