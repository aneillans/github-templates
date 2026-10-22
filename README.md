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
  setup-node-cache/             setup-node + optional npm cache, used by the Node templates
  export-secrets/               named secrets -> masked env vars, used by dotnet-ci and terraform-deploy
  resolve-deploy/               pick and verify the commit a deploy job ships
  tag-release/                  tag a deployed commit and publish a GitHub Release
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
- Helm, resolve-deploy, tag-release: no self-test; they need a cluster, a
  registry holding SHA-tagged images, or write access to create releases.
- .NET: build, test and pack. Nothing is published.

## Build and deploy conventions

The deploy actions rely on two conventions set at build time:

- Every image is tagged with the full commit SHA. docker-build-push adds this
  tag by default, alongside `sha-<short>`, the branch and `latest`. Deploys
  always use the full-SHA tag, which never moves.
- The build version is baked into the image as an environment variable, e.g.
  `ARG VERSION` then `ENV APP_VERSION=$VERSION` in the final stage. Use semver,
  optionally with `+<short sha>` build metadata.

A deploy workflow then needs no record of builds beyond the registry: an image
tagged with a commit's SHA exists only if the build for that commit passed.

```yaml
jobs:
  resolve:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: read
    outputs:
      sha: ${{ steps.resolve.outputs.sha }}
      version: ${{ steps.resolve.outputs.version }}
    steps:
      - id: resolve
        uses: aneillans/github-templates/actions/resolve-deploy@v1
        with:
          images: |
            ghcr.io/my-org/my-app-api
            ghcr.io/my-org/my-app-worker
          run_sha: ${{ github.event.workflow_run.head_sha }}
          sha: ${{ inputs.sha }}
          # production only takes commits on main
          require_branch: ${{ inputs.environment == 'production' && 'main' || '' }}
          version_env: APP_VERSION
          registry: ghcr.io
          registry_username: ${{ github.actor }}
          registry_password: ${{ secrets.GITHUB_TOKEN }}

  # ... deploy jobs use needs.resolve.outputs.sha as the image tag ...

  release:
    needs: [resolve, deploy]
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: aneillans/github-templates/actions/tag-release@v1
        with:
          sha: ${{ needs.resolve.outputs.sha }}
          version: ${{ needs.resolve.outputs.version }}
```

resolve-deploy takes the commit from `run_sha`, then `sha`, then the newest
commit on `search_branch` (default `main`) that has images. It fails if any
listed image is missing for that commit, or if the commit isn't in
`require_branch`'s history. tag-release drops `+build` metadata, so
`1.4.3+cf25037` becomes `v1.4.3`, and fails if the tag already exists.

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

### Name-mapped secrets

Some templates need an open-ended set of secrets, so the caller names them in
an input and makes its secrets available to the template, which looks each
name up. How the caller does that depends on who owns the calling repo:

- Same owner as this repo (`aneillans/*`): `secrets: inherit`.
- Any other owner (e.g. `PostyFox/*`): GitHub only honours `secrets: inherit`
  within one org or enterprise, and silently passes nothing otherwise. Pass
  the `secrets_json` secret instead:

  ```yaml
      secrets:
        secrets_json: ${{ toJSON(secrets) }}
  ```

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
- Both forms hand the template every repo and org secret the caller can see,
  not just the mapped ones.

### Environment secrets

A job that calls a reusable workflow can't set `environment:`, so the caller
can't read environment-scoped secrets and pass them on. The template job runs
under the environment and reads them itself. Templates with an `environment`
input (terraform-deploy, cloudflare-worker-deploy, helm-deploy) support this:

- Name-mapped inputs resolve environment secrets and variables directly, and
  take them over a `secrets_json` entry of the same name. Repo and org secrets
  in the same mapping still need `secrets: inherit` or `secrets_json`.
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