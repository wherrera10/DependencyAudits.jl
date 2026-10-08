using Test, TOML, RegistryInstances, DependencyAudits

@testset "DependencyAudits" begin

    @testset "basic project audit" begin
        mktempdir() do dir
            # Project.toml with one used and one unused dependency
            open(joinpath(dir, "Project.toml"), "w") do io
                TOML.print(io, Dict(
                    "name" => "TestPkg",
                    "uuid" => "00000000-0000-0000-0000-000000000001",
                    "version" => "0.1.0",
                    "deps" => Dict(
                        "JSON"      => "682c06a0-de6a-54ab-a142-c8b1cf79cde6",
                        "UnusedDep" => "11111111-1111-1111-1111-111111111111",
                    ),
                ))
            end

            src = joinpath(dir, "src")
            mkpath(src)

            write(joinpath(src, "TestPkg.jl"), """
                module TestPkg
                using JSON
                using LinearAlgebra
                using MissingPkg
                end
            """)

            write(joinpath(src, "extra.jl"), """
                using Dates
                import JSON
            """)

            # ---- finddependencies ----
            deps = finddependencies(dir)
            @test :JSON          ∈ deps
            @test :LinearAlgebra ∈ deps
            @test :Dates         ∈ deps
            @test :MissingPkg    ∈ deps
            @test :UnusedDep     ∉ deps

            # ---- finddependencyuses ----
            uses = finddependencyuses(dir)
            @test sort(replace.(uses[:JSON], "\\" => "/"))          == ["src/TestPkg.jl", "src/extra.jl"]
            @test sort(replace.(uses[:LinearAlgebra], "\\" => "/")) == ["src/TestPkg.jl"]
            @test sort(replace.(uses[:Dates], "\\" => "/"))         == ["src/extra.jl"]
            @test sort(replace.(uses[:MissingPkg], "\\" => "/"))    == ["src/TestPkg.jl"]

            # ---- audit_project ----
            audit = auditdependencies(dir)

            @test audit.projectpath == joinpath(dir, "Project.toml")
            @test :JSON      ∈ audit.declared
            @test :UnusedDep ∈ audit.declared
            @test :JSON      ∈ audit.used
            @test :LinearAlgebra ∈ audit.used
            @test :Dates     ∈ audit.used
            @test :MissingPkg ∈ audit.used

            @test :UnusedDep ∈ audit.unused
            @test :MissingPkg ∈ audit.undeclared
            @test :LinearAlgebra ∈ audit.stdlibs
            @test :Dates         ∈ audit.stdlibs

            # nothing should be both unused and missing
            @test isempty(intersect(audit.unused, audit.undeclared))
        end
    end

    @testset "exclude directories" begin
        mktempdir() do dir
            open(joinpath(dir, "Project.toml"), "w") do io
                TOML.print(io, Dict(
                    "name" => "ExclPkg",
                    "uuid" => "00000000-0000-0000-0000-000000000002",
                    "deps" => Dict{String,Any}(),
                ))
            end

            # source in the main tree
            write(joinpath(dir, "main.jl"), "using MainDep")

            # source that should be ignored
            testdir = joinpath(dir, "test")
            mkpath(testdir)
            write(joinpath(testdir, "runtests.jl"), "using TestOnlyDep")

            deps_default = finddependencies(dir)
            @test :MainDep     ∈ deps_default
            @test :TestOnlyDep ∉ deps_default

            # force-include the test directory
            deps_all = finddependencies(dir; exclude=String[])
            @test :MainDep     ∈ deps_all
            @test :TestOnlyDep ∈ deps_all
        end
    end

    @testset "empty project" begin
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), """
                name = "Empty"
                uuid = "00000000-0000-0000-0000-000000000003"
                [deps]
            """)
            audit = auditdependencies(dir)
            @test isempty(audit.declared)
            @test isempty(audit.used)
            @test isempty(audit.unused)
            @test isempty(audit.undeclared)
            @test isempty(audit.stdlibs)
        end
    end

    @testset "syntax errors are non-fatal" begin
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), """
                name = "BadSyntax"
                uuid = "00000000-0000-0000-0000-000000000004"
                [deps]
            """)
            write(joinpath(dir, "broken.jl"), """
                using Foo
                This should generate a warning as it is read by parseall because  it is not valid julia code.
            """)
            # must not throw
            deps = finddependencies(dir)
            @test isempty(deps) # if there are initial syntax errors, no dependencies should be found
        end
    end

    @testset "relative imports are ignored" begin
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), """
                name = "Rel"
                uuid = "00000000-0000-0000-0000-000000000005"
                [deps]
            """)
            write(joinpath(dir, "rel.jl"), """
                using .LocalMod
                import ..ParentMod
                using AbsoluteMod
            """)
            deps = finddependencies(dir)
            @test :AbsoluteMod ∈ deps
            @test :LocalMod    ∉ deps
            @test :ParentMod   ∉ deps
        end
    end

    @testset "using A: b and import A as B" begin
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), """
                name = "Colon"
                uuid = "00000000-0000-0000-0000-000000000006"
                [deps]
            """)
            write(joinpath(dir, "colon.jl"), """
                using Foo: bar, baz
                import Bar as Baz
                using A.B.C
            """)
            deps = finddependencies(dir)
            @test :Foo ∈ deps
            @test :Bar ∈ deps
            @test :A   ∈ deps
            # the imported names themselves must not appear
            @test :bar ∉ deps
            @test :baz ∉ deps
            @test :Baz ∉ deps
            @test :B   ∉ deps
            @test :C   ∉ deps
        end
    end

    @testset "import forms" begin
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), """
                name = "ImportForms"
                uuid = "00000000-0000-0000-0000-000000000006"
                [deps]
            """)

            write(joinpath(dir, "imports.jl"), """
                using Foo
                import Bar

                using A.B.C
                import D.E.F

                using G: g1, g2
                import H: h1, h2

                import I as J
                using K: k as l

                using M.N: n1, n2
                import O.P: p1, p2

                using .LocalMod
                using .LocalMod.SubMod
                import ..ParentMod
                import ..ParentMod.SubMod
                using ...GrandParentMod
                import ...GrandParentMod.SubMod

                using Q, R.S
                import T, U.V
            """)

            deps = finddependencies(dir)

            # Simple absolute imports.
            @test :Foo ∈ deps
            @test :Bar ∈ deps

            # Absolute dotted imports: only the package/module root matters.
            @test :A ∈ deps
            @test :D ∈ deps

            # Colon forms: record the module, not imported names.
            @test :G ∈ deps
            @test :H ∈ deps
            @test :g1 ∉ deps
            @test :g2 ∉ deps
            @test :h1 ∉ deps
            @test :h2 ∉ deps

            # Aliases: record the imported module, not the alias.
            @test :I ∈ deps
            @test :J ∉ deps
            @test :K ∈ deps
            @test :L ∉ deps

            # Dotted module paths with colon imports.
            @test :M ∈ deps
            @test :O ∈ deps
            @test :N ∉ deps
            @test :P ∉ deps
            @test :n1 ∉ deps
            @test :n2 ∉ deps
            @test :p1 ∉ deps
            @test :p2 ∉ deps

            # Relative imports must not be treated as external dependencies.
            @test :LocalMod ∉ deps
            @test :ParentMod ∉ deps
            @test :GrandParentMod ∉ deps
            @test :SubMod ∉ deps

            # Multiple imports in one statement.
            @test :Q ∈ deps
            @test :R ∈ deps
            @test :T ∈ deps
            @test :U ∈ deps
            @test :S ∉ deps
            @test :V ∉ deps
        end
    end

    @testset "include_extras / include_weakdeps" begin
        mktempdir() do dir
            open(joinpath(dir, "Project.toml"), "w") do io
                TOML.print(io, Dict(
                    "name" => "ExtrasPkg",
                    "uuid" => "00000000-0000-0000-0000-000000000007",
                    "deps" => Dict("CoreDep" => "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                    "extras" => Dict("ExtraDep" => "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
                    "weakdeps" => Dict("WeakDep" => "cccccccc-cccc-cccc-cccc-cccccccccccc"),
                    "targets" => Dict("test" => ["ExtraDep"]),
                ))
            end
            write(joinpath(dir, "src.jl"), "using CoreDep")

            audit = auditdependencies(dir)
            @test :CoreDep  ∈ audit.declared
            @test :ExtraDep ∉ audit.declared
            @test :WeakDep  ∉ audit.declared

            audit_ex = auditdependencies(dir; include_extras=true)
            @test :ExtraDep ∈ audit_ex.declared

            audit_w = auditdependencies(dir; include_weakdeps=true)
            @test :WeakDep ∈ audit_w.declared
        end
    end

    @testset "report does not throw" begin
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), """
                name = "Report"
                uuid = "00000000-0000-0000-0000-000000000008"
                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
            """)
            write(joinpath(dir, "a.jl"), "using JSON\nusing MissingOne")
            audit = auditdependencies(dir)
            # capture output just to make sure it runs
            buf = IOBuffer()
            auditreport(audit; io=buf)
            out = String(take!(buf))
            @test occursin("MissingOne", out)
            @test occursin("JSON", out)
        end
    end

    @testset "uuidof registry lookups" begin
        if isnothing(DependencyAudits.REGISTRY)
            @test uuidof("RegistryInstances") === nothing
        else
            @test uuidof("RegistryInstances") == "2792f1a3-b283-48e8-9a74-f99dce5104f3"
            @test uuidof(RegistryInstances) == "2792f1a3-b283-48e8-9a74-f99dce5104f3"
            @test uuidof("NonExistentPackage") === nothing
        end
    end

    @testset "version functions" begin
        @test versionof(RegistryInstances) == v"0.1.0"
        @test length(registeredversions("Accessors")) > 40
        @test v"0.1.40" < versionof("Accessors") < v"0.3"
        @test registeredversions("RegistryInstances") !== nothing
    end

    @testset "packagestrings function" begin
        ps = packagestrings("RegistryInstances")
        @test ps.name == "RegistryInstances"
        @test ps.uuid == uuidof("RegistryInstances")
        @test ps.version == latestversion("RegistryInstances")
    end

    @testset "audit and report" begin
        audit = auditdependencies(pwd())
        @test all(x -> x in 
           [:DependencyAudits, :JuliaSyntax, :RegistryInstances, :TOML, :Test],
           audit.used)
        @test all(x -> x in [:TOML, :Test], audit.stdlibs)
        io = IOBuffer()
        auditreport(audit; io=io)
        out = String(take!(io))
        @test occursin("Audit", out)
        @test occursin("RegistryInstances", out)
        @test occursin("TOML", out)
    end        

end

true
