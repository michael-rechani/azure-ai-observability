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
- Trivy scans Bicep after compiling each module to an ARM template. It uses the pinned scanner's embedded policies; on a fresh runner, a cache-miss message before the embedded-policy fallback is expected. The workflow tests its Azure ARM scanner against an intentionally insecure ARM 2.0 fixture and checks that expected modules and a storage rule were evaluated. Findings are **report-only**; the workflow retains the generated templates and JSON report as an artifact rather than attributing generated line numbers to Bicep source. Trivy does not currently recognize the subscription-scoped budget module, which requires separate review. ARM expressions are not evaluated, so findings can include false positives or miss configuration-dependent issues.

These are static checks, not a guarantee of security or a review of deployed Azure resources. The scanners may not understand every Azure resource or expression. Review their findings, access controls, public endpoints, cost-collector permissions, and your own Azure configuration before production use.

## Optional cost-pipeline storage

The deployment storage account enables seven-day soft delete for blobs and containers and sends Blob `StorageRead` diagnostics to the monitoring workspace. Workspace ingestion and retention can incur charges. The account still has a public network endpoint; anonymous blob access and shared-key authentication are disabled, and the Function uses Entra authorization. A private endpoint and customer-managed keys are not provisioned by default because they require customer-specific networking, DNS, and key-lifecycle decisions. Review those requirements and the remaining scanner findings before production use.
