# Azure Container Apps CI/CD Runbook

A personal reference build: a minimal Dockerised app, deployed to Azure Container Apps via GitHub Actions, authenticated with Azure using OIDC. Azure infra is built manually then rebuilt using Terraform.  

Assumes the following installed locally:

Homebrew

GIT 

Python

Django  (for the app itself)

Docker

Azure CLI  with an Azure subscription thats its logged into 

Github account 

Github CLI

Terraform

If any of that isn't set up yet, refer to Appendix A (macOS/zsh install notes).

### Summary of Sections

1. GitHub repo and minimal app: You are creating a new django app locally and testing it works in a docker
2. Manual Infra build step 1 - Initial Azure setup: Using Azure CLI, you start to create the Azure environment to run the app by creating a Resource Group to house all the services in Azure and an Azure Container Registry to house the containers you will deploy
3. Manual Infra build step 2 - Create the Azure Container Apps environment and app: You then create the Azure container environment and app using Azure CLI 
4. CI pipeline step 1 - Create OIDC identity for Azure to use to authenticate with github 
5. CI pipeline step 2 - Running the github CI pipeline:  you can now deploy the app through a github action (deploy.yml)
6. Verify the CI pipeline ran and the app is up and running on Azure
7. Terraform: converting the manual build to IaC  - now we have a working example, we will beuild the same infrastructure in Azure but using Terraform
8. Azure Cleanup for steps 2-3 (Azure CLI commands) 
9. Azure Cleanup for Terraform

 
---

## 1. GitHub repo and minimal app 
## Prerequisite: django, Docker and git installed locally

```bash
mkdir aca-practice && cd aca-practice
git init
django-admin startproject core .
```

Assign `ALLOWED_HOSTS` an adapted  value that allows requests to be answered in a Docker `django-admin startproject` generates `ALLOWED_HOSTS = []` hardcoded, which rejects any request other than from localhost or 127.0.0.1
we can set a value oveeride as "*" in .env file (see below)

```bash
python3 - << 'EOF'
path = "core/settings.py"
with open(path) as f:
    content = f.read()

content = content.replace(
    "ALLOWED_HOSTS = []",
    'ALLOWED_HOSTS = os.environ.get("DJANGO_ALLOWED_HOSTS", "").split(",") if os.environ.get("DJANGO_ALLOWED_HOSTS") else []'
)

with open(path, "w") as f:
    f.write(content)
EOF
```

`core/settings.py` already imports `os` by default (for `BASE_DIR`), so no extra import is needed. Django treats a literal `"*"` in `ALLOWED_HOSTS` as an explicit wildcard, which is what makes the `.env` value below actually take effect, rather than just sitting in the environment unused.

Add a `.env` file for local config, rather than baking it into the image 

```bash
cat > .env << 'EOF'
DJANGO_ALLOWED_HOSTS=*
EOF
```

Confirm `.env` is already covered by the `.gitignore` from earlier, it should never be committed as it will contain sensitive data -key values etc, it's local-only config.

Add a minimal `Dockerfile`, no `ENV` line, config comes in at run time instead:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN pip install django gunicorn azure-identity azure-keyvault-secrets
COPY . .
EXPOSE 8000
CMD ["gunicorn", "core.wsgi:application", "--bind", "0.0.0.0:8000"]
```

Test it builds and runs locally before moving on to Azure, passing `.env` in explicitly with `--env-file`:

```bash
docker build -t aca-practice .
docker run --env-file .env -p 8000:8000 aca-practice
# check http://localhost:8000 serves django site
```

Push to a new GitHub repo (create it on github.com first, then):

```bash
git add .
git commit -m "Initial Dockerised Django app"
git branch -M main
git remote add origin https://github.com/<your-username>/aca-practice.git
git push -u origin main
```

---

## 2. Manual Infra build step 1 - Initial Azure setup:  Create an Azure Resource Group and ACR (using Azure CLI, so you see the resources)
## Prerequisites:  Azure CLI and docker installed

```bash
az group create --name rg-aca-practice --location uksouth

az acr create \
  --resource-group rg-aca-practice \
  --name acapracticeacr \
  --sku Basic
```

Registry names must be globally unique and alphanumeric only, adjust if taken.

Build and push one image manually to confirm the registry works before automating it:

```bash
az acr login --name acapracticeacr
docker tag aca-practice acapracticeacr.azurecr.io/aca-practice:manual
docker push acapracticeacr.azurecr.io/aca-practice:manual
```

---

## 3. Manual Infra build step 2 - Create the Azure Container Apps environment and app:
## Prerequisites: Azure CLI
 
check you are logged in to the right azure subscription  
```bash
az account show
```
if you aren't, then just login again
```bash
az login
```

add the extension first to allow containerapp commands, then create a container app environment and finally a containerapp

```bash
az extension add --name containerapp --upgrade

az containerapp env create \
  --name env-aca-practice \
  --resource-group rg-aca-practice \
  --location uksouth

az containerapp create \
  --name aca-practice-app \
  --resource-group rg-aca-practice \
  --environment env-aca-practice \
  --image acapracticeacr.azurecr.io/aca-practice:manual \
  --target-port 8000 \
  --ingress external \
  --registry-server acapracticeacr.azurecr.io \
  --registry-identity system \
  --env-vars 'DJANGO_ALLOWED_HOSTS=*'
```

The single quotes around `'DJANGO_ALLOWED_HOSTS=*'` matter in zsh specifically: an unquoted `*` gets treated as a filename glob, and zsh's default behavior is to abort the whole command with a "no matches found" error rather than passing the literal `*` through, so this doesn't run without them.

Since the Dockerfile no longer bakes `DJANGO_ALLOWED_HOSTS` in, `--env-vars` here is what sets it in Azure, the `.env` file only ever covers local `docker run`, it's never read inside Azure. This is the same shape as section 7's Key Vault step, config supplied at the platform level rather than baked into the image.

`--registry-identity system` uses the Container App's own system-assigned managed identity to pull from ACR, rather than a stored registry password, worth doing even in the manual step so the identity exists ready for later. Grant it the `AcrPull` role:

```bash
ACR_ID=$(az acr show --name acapracticeacr --query id -o tsv)
PRINCIPAL_ID=$(az containerapp show --name aca-practice-app --resource-group rg-aca-practice --query identity.principalId -o tsv)

az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role AcrPull \
  --scope "$ACR_ID"
```

Confirm it's live, by using the command below. The command output includes a `.azurecontainerapps.io` URL, or fetch it with:

```bash
az containerapp show --name aca-practice-app --resource-group rg-aca-practice \
  --query properties.configuration.ingress.fqdn -o tsv
```

---

## 4. CI pipeline step 1 - OIDC federated identity for GitHub Actions to allow GitHub to push new image to Azure ACR (manual)

This replaces a stored Azure credential/secret with a trust relationship: GitHub issues a short-lived token per workflow run, Azure trusts it for this specific repo, no long-lived secret to leak or rotate.

To create the OIDC run scripts/setup-deploy-oidc.sh

```bash
bash scripts/setup-deploy-oidc.sh
```

---

## 5. CI pipeline step 2 - Running the github CI pipeline

Adding the file `.github/workflows/deploy.yml` and pushing to github on main branch triggers the action to deploy the app to Azure:

Push a small change to `main` and watch the Actions tab, this is the point where you've proven the whole chain: commit, build, push to ACR, deploy, all via OIDC with nothing stored.

Once the infrastructure is built by Terraform (section 7) there are two Container Apps, `aca-app-staging` and `aca-app-production`, and `deploy.yml` runs as four jobs:

1. `build` builds the image once, tags it with the commit SHA and pushes it to ACR
2. `deploy-staging` deploys that tag to `aca-app-staging` automatically
3. `approve-production` waits for a reviewer to approve in GitHub (the `app-deploy-production` GitHub Environment, see section 7)
4. `deploy-production` deploys the same tag to `aca-app-production`. Nothing is rebuilt, production gets the image staging is already running

### Pipelines only run when code changes

Each pipeline is filtered to the files it cares about, so editing the README or a helper script does not start a run:

| Workflow | Runs on a push to `main` when these change |
|---|---|
| `deploy.yml` (app) | `core/**`, `manage.py`, `Dockerfile`, `.github/workflows/deploy.yml` |
| `terraform-apply.yml` (infra) | `infra/**` |

Anything else (`README.md`, `docs/**`, `scripts/**`, `.gitignore`) triggers neither. The one exception is `terraform-plan.yml`: it still starts on every pull request, because `main`'s branch protection requires its `plan` check, but it plans nothing and finishes quickly when no `infra/` files changed (see section 7).

To make this work, all the `*.sh` helper scripts moved out of `infra/` into a top-level `scripts/` folder. They are one-off setup tools you run by hand, not Terraform code, and while they lived under `infra/` every edit to one matched `infra/**` and started a full Terraform plan (and approval gates) for a change that touches no infrastructure. Run them as `bash scripts/<name>.sh`.

Why it matters:

- Fewer pipeline executions, so fewer GitHub Actions minutes used and a quieter Actions tab where every run means something.
- No needless image builds, ACR pushes or new Container App revisions for a docs change.
- No approval requests for production deploys or infra applies that would change nothing.

If you do need to redeploy without touching app code (for example to re-run a failed deploy), use "Re-run all jobs" on the earlier run in the Actions tab.

---

## 6. Verify the CI pipeline ran

check the response from the live URL
```bash
curl -I https://$(az containerapp show --name aca-practice-app --resource-group rg-aca-practice \
  --query properties.configuration.ingress.fqdn -o tsv)
```
Check the Container App's revision list to confirm an app is deployed and is active - you can repeat this command each time a deployment happens

```bash
az containerapp revision list --name aca-practice-app --resource-group rg-aca-practice -o table
```

## 7 Terraform: converting the manual build to IaC
## Prerequisites: Terraform

This replaces the manual `az` commands in sections 2-3 with Terraform resources to manage the deployment of infrastructure

### Create the Terraform State backend first

Terraform's state file has to live somewhere both you and, later, CI can reach. The standard pattern on Azure is a storage account with blob storage as the backend, which also gives you locking for free via blob leasing 

To setup state, run scripts/bootstrap-state.sh and copy the values echo'd out into backend.hcl file (copied from backedn.hcl.example)

```bash
bash scripts/bootstrap-state.sh
```
Storage account names are globally unique and alphanumeric only, same constraint as ACR. This state storage account sits outside the resource group Terraform itself manages, deliberately, so a `terraform destroy` of the app infrastructure can never touch its own state backend.

### At this point install terraform, if required (see Appendix A)

### How the Terraform is laid out

The infrastructure is split into two layers, each with its own directory and its own state file in the state storage account:

| Layer | Directory | State key | What it owns |
|---|---|---|---|
| Platform | `infra/platform` | `aca-practice-platform.tfstate` | Resource group `rg-inspire-app1`, ACR `acrinspireapp1`, Log Analytics workspace, Container Apps Environment. |
| Environment (staging) | `infra/environment` | `aca-practice-staging.tfstate` | Container App `aca-app-staging`, its identity and its AcrPull role assignment, its Key Vault and the identity's read access to it |
| Environment (production) | `infra/environment` | `aca-practice-production.tfstate` | Container App `aca-app-production` |

The environment layer is one set of Terraform files applied twice, once with `environment=staging` and once with `environment=production` (both set in `.github/workflows/terraform-plan.yml` and `.github/workflows/terraform-apply.yml`)  Both Container Apps run inside the one shared Container Apps Environment. The environment layer finds the platform resources by name, so the platform layer has to be applied first.

The word "environment" means three different things in this project, keep them apart:

- the Terraform variable `environment` is `staging` or `production` and picks which Container App is being managed
- the Container Apps Environment is the Azure resource both Container Apps run inside (platform layer)
- a GitHub Environment (`infra-apply`, `infra-apply-production`, `app-deploy-production`) is only an approval gate in GitHub, the names are deliberately not `staging` / `production` so they can't be mistaken for the Terraform variable

### To test, run Terraform commands locally to plan

`backend.hcl` holds the storage account details but no `key`, because each layer has its own state file. Pass the key at init:

```bash
cd infra/platform
terraform init -backend-config=../backend.hcl -backend-config="key=aca-practice-platform.tfstate"
terraform fmt -check -recursive
terraform validate
terraform plan
```

```bash
cd infra/environment
terraform init -reconfigure -backend-config=../backend.hcl -backend-config="key=aca-practice-staging.tfstate"
terraform validate
terraform plan -var="environment=staging"
```

For production, init again with `-reconfigure` and `key=aca-practice-production.tfstate`, then plan with `-var="environment=production"`. Always re-init before switching between staging and production, the state key and the variable have to match.

If those plans look right, you've proven the whole local loop end to end, and you're ready to open a PR and watch the plan workflow do the same thing in CI.

### Setup OIDC for Terraform - same principle as OIDC for the deploy

To create the OIDC for Terraform to use, run scripts/setup-terraform-oidc.sh

```bash
bash scripts/setup-terraform-oidc.sh
```

Neither OIDC script needs running again for the staging / production split, the app registrations and their federated credentials are unchanged. What does need redoing after the platform and the Container Apps are first created (or recreated) is the role assignments on them, because those are scoped to the resources themselves:

```bash
TF_SP=$(az ad sp list --display-name github-aca-practice-terraform --query "[0].id" -o tsv)
DEPLOY_SP=$(az ad sp list --display-name github-aca-practice-deploy --query "[0].id" -o tsv)
ACR_ID=$(az acr show -n acrinspireapp1 -g rg-inspire-app1 --query id -o tsv)

# after the platform layer's first apply (the environment layer's apply fails without the first one)
az role assignment create --assignee-object-id "$TF_SP" --assignee-principal-type ServicePrincipal --role "User Access Administrator" --scope "$ACR_ID"
az role assignment create --assignee-object-id "$DEPLOY_SP" --assignee-principal-type ServicePrincipal --role AcrPush --scope "$ACR_ID"

# after each environment's first apply
for app in aca-app-staging aca-app-production; do
  az role assignment create --assignee-object-id "$DEPLOY_SP" --assignee-principal-type ServicePrincipal \
    --role "Container Apps Contributor" \
    --scope "$(az containerapp show -n "$app" -g rg-inspire-app1 --query id -o tsv)"
done
```

Check the two display names match your app registrations first (`az ad app list --query "[].displayName" -o tsv`).

### Setup the GitHub Environments used as approval gates

These three environments, and the branch protection on `main`, are set up by a script:

```bash
bash scripts/setup-github-protection.sh
```

| GitHub Environment | Gates | Required reviewers | Admins can bypass | Deployment branches |
|---|---|---|---|---|
| `infra-apply` | applying the platform layer | yes | no | Selected branches, `main` only |
| `infra-apply-production` | applying the production environment layer | yes | no | Selected branches, `main` only |
| `app-deploy-production` | deploying the app to `aca-app-production` | yes | no | Selected branches, `main` only |

"Admins can bypass" is off so the reviewer and branch rule apply to the repo owner too, otherwise the owner could skip the gate. Prevent self-review is left off because there could be only one reviewer. The script also sets `main`'s branch protection: the `plan` status check (see below) must pass before merging.

To check the live settings against this, use the VERIFY commands at the bottom of the script.

Staging has no GitHub Environment at all, it applies and deploys automatically.

### Github action: terraform plan on a pull request

`.github/workflows/terraform-plan.yml` runs on any pull request touching `infra/**`. It plans only the layers the PR changed (a change under `infra/platform` plans the platform, a change under `infra/environment` plans both staging and production) and posts each plan as a comment on the PR. Nothing is applied.

The workflow runs on every pull request (not just ones touching `infra/`) because `main`'s branch protection requires its final job, named exactly `plan`. That job passes when all planned layers succeed, or when nothing needed planning. Without it, an app-only pull request would wait forever for a check that never reports.

### Github action: terraform apply on a push to main

`.github/workflows/terraform-apply.yml` runs on a push to main touching `infra/**`:

1. `plan-platform` plans the platform layer and saves the plan
2. `apply-platform` waits for approval on `infra-apply`, then applies that saved plan
3. `plan-environments` plans staging and production side by side and saves both plans
4. `apply-staging` applies the staging plan automatically
5. `approve-production` waits for approval on `infra-apply-production`
6. `apply-production` applies the production plan that was saved in step 3

Promotion to production never plans again, it applies the plan file produced at the same time as the staging one, from the same commit. If production's state has changed in the meantime Terraform rejects the saved plan as stale, re-run the workflow to get a fresh one. A layer with nothing to change skips its apply and its approval.

The approval jobs (`approve-production` in both workflows) are separate jobs that do nothing except wait for the reviewer. That is deliberate: a job with an `environment:` line gets a different OIDC subject (`environment:<name>` instead of `ref:refs/heads/main`), which would need a new federated credential in Azure. Keeping the gate in its own job means the job that actually talks to Azure still uses the existing push-to-main credential.

### Storing a secret in Azure Key Vault, and reading it from Django

An end to end example of the usual pattern: a script puts a secret value into Azure Key Vault, and the running app reads it with its managed identity, with no password or key stored anywhere in the code, the image, the environment variables or the Terraform state.

```
scripts/set-keyvault-secret.sh --> Key Vault (one per environment) <-- core/keyvault.py <-- GET /secret/
   you, via az login        secret value, versioned           app's managed identity
```

**The pieces**

| What | Where |
|---|---|
| The vault, the app identity's read-only role on it, and audit logging | `infra/environment/keyvault.tf` |
| The vault's address, the secret's name and the identity's client ID passed to the app as environment variables (none of them is secret) | `infra/environment/main.tf` |
| The script that asks for the value and stores it | `scripts/set-keyvault-secret.sh` |
| The code that reads it, with caching | `core/keyvault.py` |
| The page that prints it | `show_secret` in `core/urls.py`, at `/secret/` |

**Run order.** The first time:

1. Re-run `bash scripts/setup-terraform-oidc.sh`. It is safe to re-run, it skips what already exists and adds the one missing grant, User Access Administrator on the resource group, which Terraform needs to create the app identity's role assignment on the vault.
2. Merge this change so `terraform-apply.yml` creates the vaults and gives the apps their `KEY_VAULT_*` environment variables. Approve the production apply.
3. Store a value: `bash scripts/set-keyvault-secret.sh staging` (then `production` when ready). Use a dummy value.
4. The app deploy from the same merge ships the code. Visit `https://<app fqdn>/secret/` (the FQDN is in `terraform output container_app_fqdn`) and it prints the value.

Role assignments can take a few minutes to reach the vault. If the page shows "Could not read the secret", wait a little and check the container logs (`az containerapp logs show -n aca-app-staging -g rg-inspire-app1`).

To rotate, run the script again with the new value. That adds a new version of the secret and the app picks it up within a minute (`CACHE_SECONDS`). Locally, `KEY_VAULT_URL` set in `.env` plus `az login` is enough, `DefaultAzureCredential` falls back to your CLI login.

**Best practice, and where it's applied here**

- **Managed identity, no credentials.** The app authenticates as its user-assigned identity. There is no client secret to store, leak or rotate.
- **Azure RBAC, not access policies.** The vault has `rbac_authorization_enabled`. Access policies are the legacy model, separate from the rest of Azure's permissions.
- **Least privilege.** The app gets `Key Vault Secrets User` (read secret values, nothing else), scoped to its own vault. You get `Key Vault Secrets Officer` on the vault only, not a subscription-wide role. Being Owner of the subscription doesn't grant data access to the vault by itself.
- **One vault per environment.** Staging's identity can't read production's secrets, and a leak in one doesn't expose the other.
- **Secret values stay out of Terraform.** Anything in Terraform lands in plaintext in the state file. Terraform owns the vault and who can use it, the script owns the value.
- **The value is never on a command line.** The script reads it with no echo, and passes it to `az` on stdin, so it doesn't appear in shell history or the process list.
- **Expiry and content type are set** on every secret (90 days here), so stale secrets are visible and an expiry alert can be hung off them.
- **Soft delete (always on) and purge protection (production).** A deleted secret or vault is recoverable for 90 days, and with purge protection nobody can permanently delete it inside that window. Purge protection can't be turned off once on, and it locks a destroyed vault's name for 90 days, so staging leaves it off.
- **Audit logging.** Every read, write and delete, with the caller's identity, goes to the Log Analytics workspace (`AuditEvent`). Query it with `AzureDiagnostics | where ResourceProvider == "MICROSOFT.KEYVAULT"`.
- **Cache reads, reuse the client.** Vaults throttle requests, so `core/keyvault.py` caches the value for 60 seconds and builds the client once so the token is reused.
- **Errors don't leak.** The page says "Could not read the secret", the real exception goes to the container logs only.

**Not done here, worth knowing about**

- **`/secret/` prints the secret to anyone who can reach the URL.** That's what makes it a good demo and a bad design. A real app uses the secret and never displays it. Use a dummy value, and delete the view and its route when you've seen it work.
- **The vault keeps its public endpoint.** Locking it to a private endpoint or firewall needs a VNet-integrated Container Apps environment, which this practice stack doesn't have. Access is still limited to authenticated identities with a role.
- **The Terraform identity's User Access Administrator isn't restricted** to particular roles. An ABAC condition on the assignment can limit it to granting only `Key Vault Secrets User`.
- **Container Apps can also pull a Key Vault secret itself** (a `secret` block with `key_vault_secret_id`, surfaced as an environment variable), which means no SDK in the code. It fails to provision if the secret doesn't exist yet at apply time, and the value only changes when a new revision starts, which is why this example reads at runtime instead.

### Moving from the single dev stack to this layout

The earlier build used one state file (`phase1.tfstate`) and `-dev` resource names (`rg-inspire-app1-dev` and so on). None of that is carried over, the new layers create new resources with new names. Before merging the change that introduces the layers, destroy the old stack from a checkout of the commit before it:

```bash
cd infra
terraform init -backend-config=backend.hcl   # key=phase1.tfstate
TF_VAR_environment=dev terraform destroy
```

Then on the first merge: approve the platform apply, run the role assignment commands above, and re-run any jobs that failed for lack of them (the environment applies need User Access Administrator on the new ACR, the app deploy needs its roles on the new ACR and Container Apps).

---

## 8. Azure Cleanup for steps 2-3 (Azure CLI commands)

If you have manually created Azure services using 2-3, just run these commands to clear down Azure

```bash
az group delete --name rg-aca-practice --yes --no-wait
az ad app delete --id <appId>
```

## 9. Azure Cleanup for Terraform


### run Terraform destroy

Destroy in the reverse order to the build, both environments first, then the platform:

```bash
cd infra/environment
terraform init -reconfigure -backend-config=../backend.hcl -backend-config="key=aca-practice-production.tfstate"
terraform destroy -var="environment=production"

terraform init -reconfigure -backend-config=../backend.hcl -backend-config="key=aca-practice-staging.tfstate"
terraform destroy -var="environment=staging"

cd ../platform
terraform init -backend-config=../backend.hcl -backend-config="key=aca-practice-platform.tfstate"
terraform destroy
```

Review each plan, confirm with `yes`. This tears down everything Terraform
manages in `rg-inspire-app1`: the two Container Apps, their user-assigned
identities and role assignments, then the Container Apps environment, Log
Analytics workspace, ACR and the resource group itself.

The Key Vaults go too. Staging's is purged as part of the destroy, so it can be rebuilt straight away. Production's has purge protection, so it is only soft-deleted: it, and its name, stay reserved for 90 days and can't be purged early. A rebuilt production gets a clash on the vault name unless you recover the old vault (`az keyvault recover --name <vault>`) or wait. The vault name is derived from the project, environment and subscription, so changing `var.project` is the other way round it.

If you also want to remove the state that Terraform uses:

```bash
az group delete --name rg-tfstate --yes --no-wait
```

This removes the storage account and the state files inside it. Nothing is
left, not even a record of what Terraform once managed. Rebuilding from
here means redoing the backend setup from section 7 entirely.

### OIDC not touched

The two Entra app registrations for, `github-aca-practice-deploy` (deploy) and
`github-aca-practice-terraform` (infra), and their federated credentials
aren't in Terraform state and aren't in either resource group. Leave them
as-is for a retest, no reason to redo the OIDC setup each cycle.

---

## Appendix A: Install notes (macOS, zsh)

All commands assume the default zsh shell on a current macOS. Run them in order, top to bottom, each one only if you don't already have it.

**homebrew** (package manager; skip if `brew --version` already works and install is confirmed)

```zsh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Follow the printed instructions to add Homebrew to your PATH (differs slightly between Apple Silicon and Intel Macs), then confirm:

```zsh
brew --version
```

**Git** (usually already present via Xcode Command Line Tools)

```zsh
git --version   # if this prompts to install Command Line Tools, accept it
# otherwise: brew install git
```

**Python 3 and a virtual environment** (Django needs Python 3.10+)

```zsh
brew install python@3.12
python3 --version
```

**setup venv including Django**

Homebrew's Python is "externally managed" (PEP 668), a plain `pip install` at the system level will refuse to run, so always work inside a virtual environment:
```zsh
cd aca-practice
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install django gunicorn azure-identity azure-keyvault-secrets
django-admin --version
```

Add `.venv/` to `.gitignore` before your first commit. Remember to `source .venv/bin/activate` again in any new terminal tab/session before running `django-admin` or `pip`.

**Docker Desktop**

```zsh
brew install --cask docker
```

Open Docker.app once from Applications to finish setup, this starts the Docker daemon, which must be running before `docker build`/`docker run` will work. Verify with:

```zsh
docker --version
docker info   # confirms the daemon is actually running, not just installed
```

**Azure CLI**

```zsh
brew install azure-cli
az --version
az login   # opens a browser to authenticate against your Azure account
az account show   # confirms the subscription context
```

The Container Apps extension used later in the runbook:

```zsh
az extension add --name containerapp --upgrade
```

**Register resource providers.** A brand-new subscription only auto-registers a handful of commonly-used providers, so `az acr create` and later `az containerapp env create` will fail with a "subscription is not registered to use namespace" error unless these are registered first. Do this once, up front, so you don't hit the same error at each step:

```zsh
az provider register --namespace Microsoft.ContainerRegistry
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights
```

`Microsoft.ContainerRegistry` covers ACR (section 2), `Microsoft.App` covers Container Apps itself (section 3), and `Microsoft.OperationalInsights` is the Log Analytics workspace a Container Apps environment needs behind the scenes. Registration is asynchronous, so check it's finished before moving on:

```zsh
az provider show --namespace Microsoft.ContainerRegistry --query registrationState -o tsv
az provider show --namespace Microsoft.App --query registrationState -o tsv
az provider show --namespace Microsoft.OperationalInsights --query registrationState -o tsv
```

Each should return `Registered` (usually under a minute) before you run the corresponding section's commands. If you hit the same error on a different namespace later, the fix is always the same pattern: `az provider register --namespace <the-namespace-named-in-the-error>`.


**Terraform**
```zsh
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```
to check install

```zsh
terraform -version
```

**Optional: GitHub CLI** 

```zsh
brew install gh
gh auth login
gh repo create aca-practice --public --source=. --push
```

---

## Appendix B: Other dependencies and gotchas

**ACR Tasks blocked on Azure Free Trial subscriptions.** `az acr build` hands the build off to ACR Tasks, a separate managed build service, which Microsoft restricts on trial-tier subscriptions (`TasksOperationsNotAllowed`, suggesting a support request, which isn't the actual fix). This is a subscription-tier restriction, not a bug or a config error, an upgrade to Pay-As-You-Go removes it, but the pipeline in section 5 avoids it entirely by building with plain Docker inside the GitHub Actions runner instead. Worth remembering this restriction exists if a future client's Azure subscription also turns out to be a trial tier, `az acr build` would fail there the same way.

**GitHub OIDC immutable subject claims (rolled out mid-2026).** GitHub changed the `sub` claim format for OIDC tokens to prevent subject recycling on renamed or transferred repos. Repositories created, renamed, or transferred after the rollout automatically get the new format, which embeds permanent owner and repository IDs: `repo:owner@OWNERID/repo@REPOID:ref:refs/heads/main`, instead of the old plain-name format. If the federated credential in Azure was created with the old-style subject, authentication fails with `AADSTS700213: No matching federated identity record found`, and the error message conveniently includes the exact subject GitHub actually presented, use that string verbatim when fixing the credential (see section 4). Any repo created from this runbook going forward should assume the immutable format applies.

**zsh glob expansion on unquoted wildcards.** Any `az` argument containing an unquoted `*` (such as `--env-vars DJANGO_ALLOWED_HOSTS=*`) gets treated by zsh as a filename glob before it ever reaches `az`. If nothing in the current directory matches, zsh aborts the entire command with `zsh: no matches found: ...` rather than passing the literal `*` through, this is zsh's default behaviour, not a bug, and differs from bash. Always quote a value containing `*` (`'DJANGO_ALLOWED_HOSTS=*'`).

**Apple Silicon image architecture.** Docker Desktop on M-series Macs builds `arm64` images by default; Azure Container Apps runs `linux/amd64`. The manual build/push in section 2 needs an explicit platform flag to avoid a manifest mismatch:

```zsh
docker build --platform linux/amd64 -t aca-practice .
```

Use the same flag on any local `docker run` you do to test the exact image you're about to ship. This doesn't affect the pipeline itself in section 5, GitHub's hosted runners build on `linux/amd64` by default, matching what Container Apps expects, so it's only the local manual steps on an Apple Silicon Mac where this bites.

**ACR name uniqueness.** Registry names are alphanumeric only and globally unique across all of Azure, not just your subscription, confirm your chosen name is free before you get attached to it.

**Entra app registration permissions.** `az ad app create` and `az ad app federated-credential create` need permission to create app registrations in the Entra tenant. On your own free-tier subscription this is your own tenant, so it's automatic. On a client tenant (Inspire), this is one of the first things to confirm they'll grant you, don't assume it carries over.

**Free-tier quota and cost.** Container Apps and ACR both sit comfortably within free-tier limits for light practice use, but nothing here is free indefinitely, delete resources when you're done (section 8) rather than leaving the environment running between practice sessions.

---

*Sources: [Authenticate to Azure from GitHub Actions by OpenID Connect, Microsoft Learn](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect), [Update and deploy changes in Azure Container Apps, Microsoft Learn](https://learn.microsoft.com/en-us/azure/container-apps/revisions), [Manage secrets in Azure Container Apps, Microsoft Learn](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets), [az acr login, Microsoft Learn](https://learn.microsoft.com/en-us/cli/azure/acr#az-acr-login), [Using GitHub Actions Workload identity federation (OIDC) with Azure for Terraform Deployments, Microsoft Learn](https://learn.microsoft.com/en-us/samples/azure-samples/github-terraform-oidc-ci-cd/github-terraform-oidc-ci-cd), [terraform-github-actions reference implementation, Azure-Samples on GitHub](https://github.com/Azure-Samples/terraform-github-actions).*
