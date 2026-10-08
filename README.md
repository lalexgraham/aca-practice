# aca-practice

A small Django app deployed to Azure Container Apps through GitHub Actions, with Azure authenticated by OIDC (no stored credentials) and the infrastructure managed by Terraform. It is a personal practice project; the full step-by-step build is in the [runbook](docs/RUNBOOK.md).

## What's in the repo

| Path | What it is |
|---|---|
| `core/`, `manage.py`, `Dockerfile` | The Django app and its container image |
| `infra/platform/` | Terraform: resource group, ACR, Log Analytics, Container Apps Environment |
| `infra/environment/` | Terraform: one Container App, identity and Key Vault, applied once for `staging` and once for `production` |
| `scripts/` | One-off setup scripts you run by hand (OIDC, state backend, GitHub protection, Key Vault secret) |
| `.github/workflows/` | The pipelines |
| `docs/RUNBOOK.md` | The full build guide, from a local app to Terraform and approval gates |

## Pipelines

| Workflow | Runs when | What it does |
|---|---|---|
| `terraform-plan.yml` | A pull request is opened or updated | Plans only the Terraform layers the PR changed and comments the plan. Applies nothing. Its `plan` check is required to merge into `main`. |
| `terraform-apply.yml` | A push to `main` changes `infra/**` | Plans and applies the platform, then staging, then production (after approval) |
| `deploy.yml` | A push to `main` changes `core/**`, `manage.py` or `Dockerfile` | Builds one image, deploys it to staging, then to production after approval |

Changes to the README, `docs/` or `scripts/` start neither deploy nor apply, so they cost no pipeline runs.

## Working on it

Changes go through a pull request into `main`:

```bash
git checkout -b my-change
git add <files> && git commit -m "Describe the change"
git push -u origin my-change
gh pr create --fill
```

Run the local app with `python manage.py runserver`, or `docker build -t aca-practice . && docker run -p 8000:8000 aca-practice`.

## Setting it up from scratch

Follow [docs/RUNBOOK.md](docs/RUNBOOK.md). It covers prerequisites, the manual Azure build, the OIDC setup, the Terraform state backend, the approval gates, and cleaning everything up afterwards.
