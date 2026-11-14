# Contributing

Thanks for helping improve Azure AI Observatory. Small fixes can go straight to a pull request. For anything larger, or anything outside what the templates cover today (they monitor existing Microsoft Foundry and Azure OpenAI accounts and do not create or resize model deployments, instrument applications or run evaluations), please open an issue first so we can agree on the approach. This is a single-maintainer project, so reviews can take a few days.

## Set up

The offline checks need no Azure sign-in. You need:

- Python 3.12, which CI uses.
- PowerShell 7 (`pwsh`), which runs the deployment-script tests.
- The Azure CLI with Bicep (`az bicep install`).
- Terraform 1.7 or later. CI uses 1.12.2.

## Run the checks CI runs

```powershell
python .\scripts\build_dashboards.py
python .\scripts\build_demo_dashboards.py
python -m unittest discover -s .\tests -v
python -m compileall -q scripts examples tests
az bicep build --file .\infra\main.bicep --outfile "$env:TEMP\ai-observability-main.json"
az bicep build-params --file .\infra\main.example.bicepparam --outfile "$env:TEMP\ai-observability-params.json"
terraform fmt -check -recursive terraform
foreach ($stage in 'azure', 'grafana') {
    terraform "-chdir=terraform/$stage" init -backend=false -input=false -lockfile=readonly
    terraform "-chdir=terraform/$stage" validate
    terraform "-chdir=terraform/$stage" test
}
```

None of these deploy anything, and they do not replace checking against real Azure resources. The [acceptance checklist](docs/setup.md#acceptance-checklist) covers that.

## Where changes go

- **Dashboards are generated.** Edit `scripts\build_dashboards.py`, not the JSON in `dashboards\`. The local layout preview in `demo\dashboards` comes from `scripts\build_demo_dashboards.py`. Run both generators and commit their output: CI regenerates the files and fails if they differ from what is committed.
- **README screenshots** in `docs\images` are rendered from the local layout preview (see the README). If your change alters how a dashboard looks, say so in the pull request.
- **Two deployment paths.** Bicep (`infra\`) and Terraform (`terraform\`) are meant to stay equivalent. When you change one, change the other, or explain in the pull request why you did not.
- **Deployment scripts.** `scripts\deploy_bicep.ps1` and `scripts\provision_grafana.ps1` are tested against mocked `az` and Grafana calls (`tests\bicep_harness.ps1`, run by `tests\test_bicep_deployment.py`). Add or adjust a test when you change them.
- **Docs.** Update the pages in `docs\` that describe the behavior you changed.

## Pull requests

- Keep each pull request to one change, and link the related issue.
- Branch protection requires the `validate`, Gitleaks, IaC scan and Python dependency audit checks to pass.
- Say what you verified and how. If you did not run it against real Azure resources, write "not verified live". Offline checks and live checks prove different things.

## Keep real values out

Do not put secrets, tokens, subscription or tenant IDs, real resource IDs or names, email addresses, hostnames or cost figures in code, docs, screenshots, issues or pull requests. Use placeholders or synthetic values. Secret scanning and Gitleaks catch many leaks but not all of them.

## Security issues

Report suspected vulnerabilities privately, as described in [SECURITY.md](SECURITY.md), not in a public issue.

## License

This project is licensed under [Apache-2.0](LICENSE). Under section 5 of that license, a contribution you submit is licensed on the same terms unless you state otherwise.
