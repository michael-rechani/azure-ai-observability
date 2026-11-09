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
- `pip-audit` for the optional Python examples and OpenSSF Scorecard for repository supply-chain practices.
- Checkov scans the Terraform configuration. Findings are **report-only** and appear in workflow logs, an artifact, and, where permitted, GitHub code scanning. Scanner and parsing errors fail the job. Pull requests from forks or Dependabot retain the artifact but do not upload SARIF with a write token.
- Trivy scans Bicep after compiling each module to an ARM template. It uses the pinned scanner's embedded policies; on a fresh runner, a cache-miss message before the embedded-policy fallback is expected. The workflow tests its Azure ARM scanner against an intentionally insecure ARM 2.0 fixture and checks that expected modules and a storage rule were evaluated. Findings are **report-only**; the workflow retains the generated templates and JSON report as an artifact rather than attributing generated line numbers to Bicep source. Trivy does not currently recognize the subscription-scoped budget and cost-exports modules, which require separate review. ARM expressions are not evaluated, so findings can include false positives or miss configuration-dependent issues.

These static checks do not guarantee security or inspect deployed Azure resources. The scanners may not understand every Azure resource or expression. Review their findings, access controls, public endpoints, cost-collector permissions, and your Azure configuration before production.

## Optional cost-pipeline permissions

By default, the collector's identity receives subscription-wide Cost Management Reader, which includes `Microsoft.Support/*` and is not strictly read-only. Opt-in resource-group query modes use separately managed grants or deployment-managed custom roles. Switching scope does not automatically remove every existing or inherited assignment. Account filters do not limit role permissions, and Grafana Viewer is not a per-user Azure authorization boundary. See [cost permissions and migration](docs/costs.md#configure-resource-group-query-mode) before enabling or changing the pipeline.

The collector runs as an Azure Function with its own user-assigned managed identity; no GitHub workflow, repository variable or client secret can obtain that identity. A federated credential left over from the removed GitHub collector mode would still trust a GitHub subject until you delete it; see [the upgrade notes](docs/costs.md#upgrading-from-the-removed-github-actions-collector).

## Optional cost-pipeline storage

The optional cost pipeline's storage account enables seven-day soft delete for blobs and containers and sends Blob `StorageRead` diagnostics to the monitoring workspace. Workspace ingestion and retention can incur charges. The account still has a public network endpoint; anonymous blob access and shared-key authentication are disabled, and the Function uses Entra authorization. A private endpoint and customer-managed keys are not provisioned by default because they require customer-specific networking, DNS, and key-lifecycle decisions. Review those requirements and the remaining scanner findings before production use.

## Optional cost export to Azure Data Explorer

The no-Function [cost export](docs/costs.md#cost-management-export-to-azure-data-explorer-no-function) writes subscription-wide cost rows to a storage account and queries them through a dedicated Azure Data Explorer cluster. The storage account disables shared-key authentication and anonymous access, requires TLS 1.2, enables seven-day blob soft delete, and uses a firewall that denies by default with the `AzureServices` bypass, which is how the Cost Management export and the cluster's managed identity reach it. Where a tenant policy forces `publicNetworkAccess` to `Disabled`, the same bypass path still works in the Lab. It does not provision a private endpoint, customer-managed keys for the storage account or the cluster, or blob read diagnostics, so Checkov reports `CKV2_AZURE_1`, `CKV2_AZURE_11`, `CKV2_AZURE_21` and `CKV2_AZURE_33` for it. These are known and not suppressed; they involve customer-specific networking and key-lifecycle decisions. The deployer is granted **AllDatabasesAdmin** on the dedicated cluster because only that role can set the database `managed_identity` policy; remove it after deployment if you do not redeploy. Anyone who can edit queries on the Grafana ADX data source can read every cost row in the subscription, so restrict the Grafana Editor and Admin roles.
