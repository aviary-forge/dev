# dev

An attempt at making a monorepo to provide a set of common, re-usable
development components, that boost developer productivity and encourage good
habits. This project aims to use Nix to help achieve these goals.


## Goals
Assuming a familiarity with Nix, it should be relatively easy to:
- start a new project
- setup linters and pre-commit hooks (ideally some come by default)
- install tools necessary for a project
- configure ci (for linux) that runs tests, as well as standard checks
  and builds
- automatically export work (commits, tags) to external repositories
- specify code owners, and have automatic review checks
- import existing projects from git repositories

It should be annoying and/or impossible to:
- set up a project without a "buildable artifact"
  (outside of a subdirectory)
- add new files without code owners

### Longer-term goals
- set up less janky secrets management, and a more-or-less
  arbitrary deployment automation

### Non-goals
- Flake compatibility. I might look into it again someday, but I've
  personally found it lacking in larger repos, and there is a lot of contention
  around feature development and support currently

## Plan
- Set up readTree.nix
- Set up third-party deps management, pin nixpkgs
- Small tool for codeownership:
  - compiles owners files to github codeowners
  - ensures no files are unowned
- Set up a basic CI job that runs these on change
- Merge it
