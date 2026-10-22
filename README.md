# github-templates

Reusable GitHub Actions workflows (`workflow_call`) and composite actions shared
across repos, to stop CI/CD pipelines drifting from each other every
time one gets a fix the others don't.

## Design principle: templates don't know how many targets exist

A first draft of this had the Terraform template take a JSON list of accounts
as an input. That bakes an assumption into the shared repo -- "there are N
accounts, here's their names" -- that has no reason to stay true, and every
new account would mean editing github-templates instead of just the calling
repo.

Instead every template here handles **one target**: one Terraform root, one
Docker image, one .NET project, one Worker deploy. Multiplicity (accounts,
projects, environments) is a `strategy.matrix` in the *calling* repo's own
workflow file, which calls the template once per matrix entry; this is
native GitHub Actions behaviour, not a workaround. Adding an account is a
one-line diff in the calling repo; github-templates never changes.

## Structure

```
.github/workflows/
  terraform-validate.yml        fmt + validate, one Terraform root
  terraform-deploy.yml          plan/apply, one Terraform root
  docker-build-push.yml         buildx + metadata + push, one image
  dotnet-ci.yml                 restore/build/test, one project or sln
  dotnet-pack.yml               pack to nupkg, one csproj
  dotnet-nuget-publish.yml      push downloaded nupkgs to a feed
  cloudflare-worker-deploy.yml  wrangler deploy, one target
actions/
  setup-dotnet-cache/           setup-dotnet + NuGet cache, used by the .NET templates
  setup-node-cache/             setup-node + npm cache, used by the Worker template
examples/
  one migrated caller workflow per existing repo, ready to copy in
tests/
  terraform/     random_pet + terraform_data, S3 remote state in the github-templates bucket on storage.neillans.co.uk
  node-app/      HTTP server with node:test tests and a Dockerfile
  node-worker/   minimal Cloudflare Worker
  dotnet/        class library + xUnit tests, packable
```

## Self-tests

`test-terraform.yml`, `test-node.yml` and `test-dotnet.yml` call the templates
by local path (`./.github/workflows/...`), so a PR tests its own copy of the
template. Composite actions referenced inside the templates still resolve to
`@main`.

- Terraform: validate, then plan against the shared test state. Run it
  manually with `apply` to exercise apply. Needs repo secrets
  `TF_STATE_ACCESS_KEY_ID` and `TF_STATE_SECRET_ACCESS_KEY`.
- Node: `npm test`, a `wrangler deploy --dry-run`, and amd64+arm64 image
  builds through both the QEMU and native-runner paths (no push).
- .NET: build, test and pack. Nothing is published.

## Status

Nothing has been pushed anywhere and no existing repo has been touched. This
is the template repo plus example callers for review. To adopt one:

1. Push this repo to `github.com/aneillans/github-templates`, tag a release
   (see Versioning below).
2. Copy the matching file from `examples/` into the target repo's
   `.github/workflows/`, delete the old workflow file it replaces.
3. Do any one-time secret/environment setup the example's header comment
   calls out 

## Versioning

Callers should pin to a tag once this stabilises (`@v1`), not `@main`.
A bug fix here would otherwise change behaviour in every repo on the same
day with no changelog. 
While developing / iterating, `@main` or a branch head is fine since only you 
consume this repo.

## Secret handling

TBC