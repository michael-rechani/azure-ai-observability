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
- Trivy scans Bicep after compiling each module to an ARM template. It uses the pinned scanner's embedded policies; on a fresh runner, a cache-miss message before the embedded-policy fallback is expected. The workflow tests its Azure ARM scanner against an intentionally insecure ARM 2.0 fixture and checks that expected modules and a storage rule were evaluated. Findings are **report-only**; the workflow retains the generated templates and JSON report as an artifact rather than attributing generated line numbers to Bicep source. Trivy does not currently recognize the subscription-scoped budget module, which requires separate review. ARM expressions are not evaluated, so findings can include false positives or miss configuration-dependent issues.

These static checks do not guarantee security or inspect deployed Azure resources. The scanners may not understand every Azure resource or expression. Review their findings, access controls, public endpoints, optional cost-route permissions, and your Azure configuration before production.

## Optional direct cost query with Infinity

The [Infinity cost query](docs/costs.md#direct-cost-management-queries-with-infinity-opt-in) is the only optional feature that stores a secret. Infinity cannot use a managed identity, so Grafana signs in to Cost Management as a service principal with a **client secret**. Grafana stores it encrypted and never returns it through its API, but it is a long-lived credential:

- Create the secret with a bounded expiry, keep it in a secret store, and rotate it before it expires. Expiry breaks the panels without an alert.
- The Bicep path never places it in a parameter, output or deployment history: the helper reads `AI_OBSERVABILITY_COST_CLIENT_SECRET` (or `-CostInfinityClientSecret`) and sends it only to Grafana. The Terraform Grafana stage **records it in state**; supply it through `TF_VAR_cost_infinity_client_secret`, never a `.tfvars` file, and protect the state as a credential.
- It is a shared identity. Anyone who can edit queries on the data source (Grafana Editor and Admin) inherits the principal's cost access. `resourceGroupManaged` grants a custom role with only `Microsoft.CostManagement/query/read` on each monitored resource group; `subscription` grants the built-in **Cost Management Reader**, whose actions include `Microsoft.Support/*`.
- The data source sets `oauthPassThru: false` and `allowedHosts` to `https://management.azure.com`, so Infinity will not send the credential to another host.
- Remove the service principal, its role assignments and the secret when you stop using the feature.
