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
  node-ci.yml                   npm ci + lint/build/test, one package
  helm-deploy.yml               helm upgrade --install, one release
  dotnet-pack.yml               pack to nupkg, one csproj
  dotnet-nuget-publish.yml      push downloaded nupkgs to a feed
  cloudflare-worker-deploy.yml  wrangler deploy, one target
actions/
  setup-dotnet-cache/           setup-dotnet + NuGet cache, used by the .NET templates
  setup-node-cache/             setup-node + npm cache, used by the Node templates
  export-secrets/               named secrets -> masked env vars, used by dotnet-ci and terraform-deploy
tests/
  terraform/     random_pet + terraform_data, S3 remote state in the github-templates bucket on storage.neillans.co.uk
  node-app/      HTTP server with node:test tests and a Dockerfile
  node-worker/   minimal Cloudflare Worker
  dotnet/        class library + xUnit tests, packable
```

## Self-tests

`test-terraform.yml`, `test-node.yml` and `test-dotnet.yml` call the templates
by local path (`./.github/workflows/...`), so a PR tests its own copy of the
template. Composite actions referenced inside the templates resolve to `@v1`,
so the branch copy of a composite action is only exercised where a test job
uses it by local path.

- Terraform: validate, then plan against the shared test state. Run it
  manually with `apply` to exercise apply. Needs repo secrets
  `TF_STATE_ACCESS_KEY_ID` and `TF_STATE_SECRET_ACCESS_KEY`.
- Node: `node-ci`, a `wrangler deploy --dry-run`, and amd64+arm64 image
  builds through both the QEMU and native-runner paths (no push), with
  build args and a build secret on the QEMU path.
- Helm: no self-test; it needs a cluster.
- .NET: build, test and pack. Nothing is published.

## Versioning

Callers pin to the moving major tag (`@v1`), not `@main`. Templates reference
their own composite actions at `@v1` too, so after tagging a release move `v1`
to it: `git tag -f v1 vX.Y.Z && git push -f origin v1`.
A bug fix here would otherwise change behaviour in every repo on the same
day with no changelog. 
While developing / iterating, `@main` or a branch head is fine since only you 
consume this repo.

## Secret handling

Templates take secrets in one of two ways. Use whichever the template offers,
and prefer the explicit form where both work.

### Explicit secrets

Templates with a fixed set of credentials declare them under
`workflow_call.secrets`. The caller passes each one by name:

```yaml
jobs:
  image:
    permissions:
      contents: read
      packages: write
    uses: aneillans/github-templates/.github/workflows/docker-build-push.yml@v1
    with:
      registry: ghcr.io
      registry_username: ${{ github.actor }}
      image_name: my-org/my-app
    secrets:
      registry_password: ${{ secrets.GITHUB_TOKEN }}
      # one id=value per line, read in the Dockerfile with RUN --mount=type=secret,id=...
      build_secrets: |
        licence_key=${{ secrets.LICENCE_KEY }}
```

| Template | Secrets |
|---|---|
| docker-build-push | `registry_password`, `build_secrets` |
| dotnet-nuget-publish | `feed_api_key` |
| cloudflare-worker-deploy | `cloudflare_api_token`, `cloudflare_account_id` |
| terraform-deploy | `tfvars_json`, `backend_hcl` |

The template only sees what is listed.

### Name-mapped secrets (`secrets: inherit`)

Some templates need an open-ended set of secrets, so the caller names them in
an input and passes `secrets: inherit`. The template looks each name up in its
own `secrets` context.

| Template | Input | Format, one per line | Becomes |
|---|---|---|---|
| dotnet-ci | `env_secrets` | `ENV_NAME=SECRET_NAME` or `SECRET_NAME` | env var for restore/build/test |
| terraform-deploy | `env_secrets` | `ENV_NAME=SECRET_NAME` or `SECRET_NAME` | env var, e.g. `TF_VAR_x`, `CLOUDFLARE_API_TOKEN` |
| helm-deploy | `secret_values` | `helm.path=SECRET_NAME` | chart value, via a temporary values file |
| helm-deploy | `var_values` | `helm.path=VAR_NAME` | chart value from a configuration variable |
| helm-deploy | `kubeconfig_secret` | `SECRET_NAME` (default `KUBE_CONFIG`) | base64-decoded kubeconfig |

```yaml
jobs:
  ci:
    permissions:
      contents: read
      checks: write
      pull-requests: write
    uses: aneillans/github-templates/.github/workflows/dotnet-ci.yml@v1
    with:
      project: MySolution.slnx
      env_secrets: |
        LICENSE_KEY
        NUGET_TOKEN=PRIVATE_FEED_TOKEN
    secrets: inherit

  deploy:
    uses: aneillans/github-templates/.github/workflows/helm-deploy.yml@v1
    with:
      environment: production
      chart: deploy/helm/my-app
      release: my-app
      namespace: my-app
      secret_values: |
        postgres.password=DB_PASSWORD
        oauth.clientSecret=OIDC_CLIENT_SECRET
      var_values: |
        config.smtp.host=SMTP_HOST
    secrets: inherit
```

- Names are case-insensitive, as in GitHub. Whitespace in a line is stripped.
- A name that can't be found fails the job; it is never exported or rendered
  as empty. Leave optional secrets out of the mapping.
- `secrets: inherit` hands the template every repo and org secret the caller
  can see, not just the mapped ones. 

### Environment secrets

A job that calls a reusable workflow can't set `environment:`, so the caller
can't read environment-scoped secrets and pass them on. The template job runs
under the environment and reads them itself. Templates with an `environment`
input (terraform-deploy, cloudflare-worker-deploy, helm-deploy) support this:

- Name-mapped inputs resolve environment secrets and variables directly. Repo
  and org secrets in the same mapping still need `secrets: inherit`.
- Explicit secrets must be repo or org secrets, because the caller resolves
  them outside the environment.
- The environment's approvals and deployment branch policies gate the template
  job as usual.

dotnet-ci, node-ci and docker-build-push have no `environment` input and can
only use repo and org secrets.

### Other notes

- Never put a secret in `with:` or in docker-build-push's `build_args`. Inputs
  aren't treated as secrets, and build args stay in the image history. Use
  `build_secrets` for anything the Dockerfile needs at build time.
- Values from the `secrets` context are masked in logs, and `env_secrets` also
  masks each line of a multi-line value.
- Keep deploy credentials in environments with branch policies rather than
  repo secrets, so PR runs can't read them; this is just good GitHub hygiene.