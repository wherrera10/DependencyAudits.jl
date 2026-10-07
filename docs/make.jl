using Documenter, DependencyAudits

makedocs(
    sitename = "DependencyAudits Module Documentation",
    format = Documenter.HTML(prettyurls = false),
)

deploydocs(
    repo = "github.com/wherrera10/DependencyAudits.jl.git",
    devbranch = "main",
)
