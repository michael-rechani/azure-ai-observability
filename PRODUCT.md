# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Cloud operators deploy and maintain Azure AI monitoring. Business users and end users can view metrics in Grafana; their roles and access boundaries depend on the deployment.

## Product Purpose

Provide deployable monitoring for existing Microsoft Foundry and Azure OpenAI provisioned-throughput resources, so teams can understand agent behavior, model usage, service health, and, through opt-in dashboards, billed cost.

## Positioning

Combines separate Grafana dashboards with Terraform or Bicep provisioning for Azure Monitor, Log Analytics, access, and alerting. It observes existing resources; it does not create AI deployments, instrument applications automatically, or change PTU capacity.

## Operating Context

Customers deploy into their own Azure subscriptions. Grafana uses a managed identity to query explicitly configured resources and workspaces. Deployers choose one infrastructure tool; business viewers can be granted read-only Grafana access, which is not a data-isolation boundary.

## Capabilities and Constraints

- PTU metrics come from Azure Monitor; agent panels require compatible, real telemetry.
- Billed cost is not part of the default deployment. The Azure portal and an optional budget alert are the baseline; opt-in dashboards read Azure Cost Management actual cost, either live through Infinity (which needs a client secret) or from an export to Azure Data Explorer. Billing can lag, and neither route reports amortized cost.
- Screenshots and local demo dashboards use simulated data. Live Azure deployment and customer-specific telemetry must be validated in the target environment.
- Private networking, sovereign-cloud endpoints, and strict customer data separation are not provided by the starter defaults.
- The business overview summarizes observed agent activity and PTU signals, with no cost data; absent or unsupported telemetry must be shown as unavailable, not zero.

## Evidence on Hand

The repository contains Grafana dashboard JSON, simulated preview screenshots, Terraform and Bicep deployment paths, offline tests, and CI. The preview screenshots are not evidence of a live Azure deployment. Both deployment paths were also applied once in an isolated Lab subscription, where the Foundry, PTU and agent-trace panels and the PTU alerts returned or fired on real data. That run predates the removal of the optional cost pipeline, and the opt-in billed-cost routes are the least-proven part (see [billed cost options](docs/costs.md)).

## Product Principles

- Keep observations distinct from inferred health or financial conclusions.
- Show missing, stale, unsupported, or sampled data honestly; never turn it into zero.
- Default to least privilege and make access boundaries visible.
- Preserve separate business-summary and operational-diagnostic views.
