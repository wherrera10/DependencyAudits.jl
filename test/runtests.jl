using Test, TOML, DependencyAudits

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

            # ---- find_dependencies ----
            deps = find_dependencies(dir)
            @test :JSON          ∈ deps
            @test :LinearAlgebra ∈ deps
            @test :Dates         ∈ deps
            @test :MissingPkg    ∈ deps
            @test :UnusedDep     ∉ deps

            # ---- find_dependency_uses ----
            uses = find_dependency_uses(dir)
            @test sort(uses[:JSON]) == ["src/TestPkg.jl", "src/extra.jl"]
            @test uses[:LinearAlgebra] == ["src/TestPkg.jl"]
            @test uses[:Dates]         == ["src/extra.jl"]
            @test uses[:MissingPkg]    == ["src/TestPkg.jl"]

            # ---- audit_project ----
            audit = audit_project(dir)

            @test audit.project_path == joinpath(dir, "Project.toml")
            @test :JSON      ∈ audit.declared
            @test :UnusedDep ∈ audit.declared
            @test :JSON      ∈ audit.used
            @test :LinearAlgebra ∈ audit.used
            @test :Dates     ∈ audit.used
            @test :MissingPkg ∈ audit.used

            @test :UnusedDep ∈ audit.unused
            @test :MissingPkg ∈ audit.missing
            @test :LinearAlgebra ∈ audit.stdlibs
            @test :Dates         ∈ audit.stdlibs

            # nothing should be both unused and missing
            @test isempty(intersect(audit.unused, audit.missing))
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

            deps_default = find_dependencies(dir)
            @test :MainDep     ∈ deps_default
            @test :TestOnlyDep ∉ deps_default

            # force-include the test directory
            deps_all = find_dependencies(dir; exclude=String[])
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
            audit = audit_project(dir)
            @test isempty(audit.declared)
            @test isempty(audit.used)
            @test isempty(audit.unused)
            @test isempty(audit.missing)
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
                this is not valid julia !!!
            """)
            # must not throw
            deps = find_dependencies(dir)
            @test :Foo ∈ deps
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
            deps = find_dependencies(dir)
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
            deps = find_dependencies(dir)
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

            audit = audit_project(dir)
            @test :CoreDep  ∈ audit.declared
            @test :ExtraDep ∉ audit.declared
            @test :WeakDep  ∉ audit.declared

            audit_ex = audit_project(dir; include_extras=true)
            @test :ExtraDep ∈ audit_ex.declared

            audit_w = audit_project(dir; include_weakdeps=true)
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
            audit = audit_project(dir)
            # capture output just to make sure it runs
            buf = IOBuffer()
            report(audit; io=buf)
            out = String(take!(buf))
            @test occursin("MissingOne", out)
            @test occursin("JSON", out)
        end
    end

end

