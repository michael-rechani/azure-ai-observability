## What changed and why

<!-- Link the related issue. -->

## How it was checked

- [ ] If a dashboard changed: ran `scripts\build_dashboards.py` and `scripts\build_demo_dashboards.py` and committed the output
- [ ] `python -m unittest discover -s .\tests -v` passes
- [ ] If infrastructure changed: `az bicep build`, `terraform fmt`, `terraform validate` and `terraform test` pass
- [ ] If behavior changed: the pages in `docs\` are updated

**Verified against real Azure resources?** Say what you ran and where, or write "not verified live".

## Before you submit

- [ ] No secrets, tokens, subscription or tenant IDs, real resource IDs or names, email addresses, hostnames or cost figures in code, docs, screenshots or this description
