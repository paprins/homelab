# Renovate

**Automated dependency updates for your homelab repository.**

[Renovate](https://docs.renovatebot.com/) scans your Git repository and opens pull requests when it detects outdated dependencies — Helm chart versions, container image tags, GitHub Actions, and more. Instead of manually checking for updates, Renovate does it for you.

## Why Renovate

A homelab repository accumulates pinned versions everywhere: Helm chart versions in `kustomization.yaml`, container image tags in deployments, tool versions in CI workflows. Without something watching for updates, these go stale silently. Renovate catches them and opens PRs with changelogs so you can review and merge at your own pace.

## GitHub App vs self-hosted

Renovate can run in two ways:

1. **GitHub App** (hosted by Mend) — Runs as a GitHub App via the [GitHub Marketplace](https://github.com/apps/renovate). Zero infrastructure, just install the app on your repository.
2. **Self-hosted** — Run Renovate on your own infrastructure (e.g. as a CronJob in your cluster).

### Why I use the GitHub App

The self-hosted Renovate Community Edition (`mend-renovate-ce`) does **not publish `linux/arm64` Docker images**. Since this cluster runs entirely on Raspberry Pi (ARM64), the self-hosted option cannot run on our nodes.

A Kustomize-based deployment is prepared at `k3s/apps/renovate/` in case ARM64 images become available in the future, but it is **not active** — there is no ArgoCD Application pointing to it.

The GitHub App works perfectly for our use case: it runs on GitHub's infrastructure, needs no cluster resources, and has access to the repository out of the box.

## Setup

### 1. Install the Renovate GitHub App

1. Go to [github.com/apps/renovate](https://github.com/apps/renovate)
2. Click **Install**
3. Select your account and choose the repositories you want Renovate to manage (e.g. your `homelab` repo)
4. Confirm the installation

That's it — Renovate now has access to your repository.

### 2. Add a Renovate configuration

Renovate looks for a configuration file in the root of your repository. This repo uses `renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended"
  ]
}
```

The `config:recommended` preset enables sensible defaults: automatic PR creation, changelogs in PR descriptions, grouping of minor/patch updates, and respecting existing version constraints.

### 3. Wait for the onboarding PR

After installation, Renovate opens an **onboarding PR** that shows you what it detected and what it plans to do. Merge this PR to activate Renovate. From that point on, it runs automatically and opens PRs for each outdated dependency.

## What Renovate detects in this repo

Renovate understands many file formats out of the box. In this homelab repository, it picks up:

| File pattern | What it detects |
|---|---|
| `k3s/apps/*/kustomization.yaml` | Helm chart versions in `helmCharts[].version` |
| `demo/hello-world.yaml` | Container image tags (e.g. `traefik/whoami:latest`) |
| `k3s/apps/*/values.yaml` | Container image tags inside Helm values |
| `renovate.json` | Renovate's own configuration |

## Customizing Renovate

The `renovate.json` file supports many options. A few useful ones for homelabs:

**Schedule updates to specific times** (avoid surprises during the day):

```json
{
  "extends": ["config:recommended"],
  "schedule": ["before 7am on Monday"]
}
```

**Auto-merge patch updates** (trust minor version bumps):

```json
{
  "extends": ["config:recommended"],
  "packageRules": [
    {
      "matchUpdateTypes": ["patch"],
      "automerge": true
    }
  ]
}
```

**Group all Helm chart updates into one PR**:

```json
{
  "extends": ["config:recommended"],
  "packageRules": [
    {
      "matchManagers": ["helmv3", "helm-values"],
      "groupName": "Helm chart updates"
    }
  ]
}
```

See the [Renovate documentation](https://docs.renovatebot.com/configuration-options/) for the full list of options.

## Self-hosted deployment (not active)

A ready-to-use Kustomize deployment exists at `k3s/apps/renovate/` using the `mend-renovate-ce` Helm chart. It includes:

| File | Purpose |
|---|---|
| `k3s/apps/renovate/kustomization.yaml` | Kustomize config pulling the `mend-renovate-ce` Helm chart |
| `k3s/apps/renovate/values.yaml` | Helm values (GitHub platform, ingress at `renovate.geeklabs.dev`) |
| `k3s/apps/renovate/secrets.yaml` | SealedSecret with GitHub PAT and license key |

To activate this deployment once ARM64 images are available:

1. Create an ArgoCD Application at `k3s/argocd/apps/renovate.yaml` pointing to `k3s/apps/renovate`
2. Push to Git — the root Application picks it up automatically

Until then, the GitHub App handles everything.
