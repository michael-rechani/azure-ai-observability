# Security

## Reporting a vulnerability

Please report suspected vulnerabilities privately through
[GitHub's vulnerability reporting form](https://github.com/michael-rechani/azure-ai-observability/security/advisories/new).
Do not post exploit details, credentials, or customer data in a public issue.
Include the affected component, reproduction steps, and sanitized evidence where possible.

## Automated checks

- GitHub secret scanning and push protection, plus Gitleaks scanning of the checked-out Git history.
- Dependabot alerts and monthly grouped updates for GitHub Actions, Python dependencies, Terraform providers, and the Grafana Compose image.
- CodeQL default setup for Python and GitHub Actions; these languages do not cover PowerShell or infrastructure files.
- `pip-audit` for the optional Python examples and OpenSSF Scorecard for repository supply-chain practices. The CI tools (`pip-audit`, Checkov) install from hash-pinned requirements in `.github/` (`pip install --require-hashes`), which Dependabot keeps current. Checkov 3.4.3, the latest release, pins `asteval` 1.0.6 and depends on `ecdsa`, which have published advisories (no `ecdsa` fix exists). They run only in CI against this repository's own Terraform and are not shipped, so the alerts are accepted until Checkov updates them.
- Branch protection on `main`: changes go through a pull request, the `validate`, Gitleaks, IaC scan and Python dependency audit checks must pass, conversations must be resolved, history stays linear, and force-pushes and branch deletion are blocked. Required approvals are 0 because this is a single-maintainer repository, and administrators can bypass the rules so a broken check cannot lock the repository.
- Checkov scans the Terraform configuration. Findings are **report-only** and appear in workflow logs, an artifact, and, where permitted, GitHub code scanning. Scanner and parsing errors fail the job. Pull requests from forks or Dependabot retain the artifact but do not upload SARIF with a write token.
- Trivy scans Bicep after compiling each module to an ARM template. It uses the pinned scanner's embedded policies; on a fresh runner, a cache-miss message before the embedded-policy fallback is expected. The workflow tests its Azure ARM scanner against an intentionally insecure ARM 2.0 fixture and checks that expected modules and a storage rule were evaluated. Findings are **report-only**; the workflow retains the generated templates and JSON report as an artifact rather than attributing generated line numbers to Bicep source. Trivy does not currently recognize the subscription-scoped budget module or the Microsoft Graph module that creates the Infinity app registration, which require separate review. ARM expressions are not evaluated, so findings can include false positives or miss configuration-dependent issues.

These static checks do not guarantee security or inspect deployed Azure resources. The scanners may not understand every Azure resource or expression. Review their findings, access controls, public endpoints, optional cost-route permissions, and your Azure configuration before production.

## Optional direct cost query with Infinity

The [Infinity cost query](docs/costs.md#direct-cost-management-queries-with-infinity-opt-in) is the only optional feature that stores a secret. Infinity cannot use a managed identity, so Grafana signs in to Cost Management as a service principal with a **client secret**. Grafana stores it encrypted and never returns it through its API, but it is a long-lived credential:

- Both deployment paths create the app registration, service principal and role in code, so nothing is made by hand. Terraform creates the secret and rotates it on a schedule (90 days by default, with a 30-day overlap); rotate it before it expires. The Bicep path cannot create it: the helper mints a 180-day secret as the app's owner, sends it only to Grafana, and never places it in a parameter, output or deployment history. Expiry breaks the panels; the shipped alert rule detects that, but cannot warn before expiry.
- The Terraform path **records the secret in state** (both stages); supply the Grafana stage's copy through `TF_VAR_cost_infinity_client_secret`, never a `.tfvars` file, and protect the state as a credential.
- Creating the principal needs Microsoft Entra permission to create app registrations plus Owner or User Access Administrator at the scope. The Bicep path also leaves the deployer as the app's owner, which lets that user mint more secrets.
- It is a shared identity. Anyone who can edit queries on the data source (Grafana Editor and Admin) inherits the principal's cost access. Its only Azure permission is a custom role with the single action `Microsoft.CostManagement/query/read` (no write, delete or `Microsoft.Support/*` actions), assigned on the subscription by default or on each monitored resource group for `resourceGroupManaged`. It is read-only, but it can read all cost data at that scope.
- The data source sets `oauthPassThru: false` and `allowedHosts` to `https://management.azure.com`, so Infinity will not send the credential to another host.
- Remove the service principal, its role assignments and the secret when you stop using the feature.
