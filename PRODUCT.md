# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Cloud operators deploy and maintain Azure AI monitoring. Customer business users and end users may view metrics through Grafana. A concise business overview for those viewers is an explicit assumption from this task; their exact roles and access boundaries remain deployment-specific.

## Product Purpose

Provide deployable monitoring for existing Microsoft Foundry and Azure OpenAI provisioned-throughput resources, so teams can understand agent behavior, model usage, service health, and optional account-attributed costs.

## Positioning

Combines separate Grafana dashboards with Terraform or Bicep provisioning for Azure Monitor, Log Analytics, access, and alerting. It observes existing resources; it does not create AI deployments, instrument applications automatically, or change PTU capacity.

## Operating Context

Customers deploy into their own Azure subscriptions. Grafana uses a managed identity to query explicitly configured resources and workspaces. Deployers choose one infrastructure tool; business viewers can be granted read-only Grafana access, which is not a data-isolation boundary.

## Capabilities and Constraints

- PTU metrics come from Azure Monitor; agent panels require compatible, real telemetry.
- Cost collection is optional, daily, and based on Azure Cost Management data attributed to configured accounts. Billing can lag; actual and amortized costs are alternatives.
- Screenshots and local demo dashboards use simulated data. Live Azure deployment and customer-specific telemetry must be validated in the target environment.
- Private networking, sovereign-cloud endpoints, and strict customer data separation are not provided by the starter defaults.
- The new business overview is assumed to summarize cost, usage, and service health; absent or unsupported telemetry must be shown as unavailable, not zero.

## Evidence on Hand

The repository contains Grafana dashboard JSON, simulated preview screenshots, Terraform and Bicep deployment paths, offline tests, and CI. The preview screenshots are not evidence of a live Azure deployment.

## Product Principles

- Keep observations distinct from inferred health or financial conclusions.
- Show missing, stale, unsupported, or sampled data honestly; never turn it into zero.
- Default to least privilege and make access boundaries visible.
- Preserve separate business-summary and operational-diagnostic views.
