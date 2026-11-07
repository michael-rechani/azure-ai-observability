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
- Checkov scans checked-in Terraform and Bicep. Its findings are **report-only** and appear in workflow logs, an artifact, and, where permitted, GitHub code scanning. Scanner and parsing errors fail the job. Pull requests from forks or Dependabot retain the artifact but do not upload SARIF with a write token.

These are static checks, not a guarantee of security or a review of deployed Azure resources. Checkov may not understand every Azure resource or expression. Review its findings, access controls, public endpoints, cost-collector permissions, and your own Azure configuration before production use.
