# Azure AI cost collection

Both deployment paths can opt into a daily PowerShell Azure Function, a detailed Grafana cost dashboard, and a business overview: `enable_cost_pipeline` plus `enable_cost_dashboard` in [Terraform](terraform.md#optional-cost-pipeline), or `enableCostPipeline` in [Bicep](bicep.md#optional-cost-collection-and-budget). The overview shows collection freshness, actual cost by currency, observed agent activity, and PTU signals without blending them into a health score. This feature has not been validated with live Azure billing data.

## What the numbers mean

The dashboard reports **pretax costs attributed by Cost Management to the exact configured AI account resource IDs**. It is not an invoice, total subscription spend, a per-deployment/PTU price, or a reservation-coverage report. Reservation purchases, shared or billing-scope charges, child-resource costs, and tax can be omitted. Actual and amortized costs are alternative views and must not be added together; currencies remain separate. Values are rounded for display.

Billing can arrive late or be revised. The collector refreshes a rolling window (90 UTC days by default); corrections older than that window are not automatically captured. Usage-day filtering is UTC and includes the full reported day when a selected range starts partway through it. Validate coverage and billing behavior with your own agreement before making financial decisions.

## Operation and permissions

The Function runs daily at **06:00 UTC**, querying each selected account for actual and amortized costs. It uses Flex Consumption with no always-ready instances; the scale-out maximum of 40 is a ceiling, not 40 running instances. It writes to a custom `AICostSnapshot_CL` table through a data collection endpoint and rule.

The Function's managed identity receives **Cost Management Reader for the entire subscription**, even though its queries filter to the selected accounts. It also receives Storage Blob Data Owner and Storage Table Data Contributor on its storage account, plus Monitoring Metrics Publisher on the data collection rule and Application Insights. Review these permissions for each customer. Grafana reads the table using its existing workspace-reader access; Viewer is not a data-isolation boundary.

Daily queries use windows of at most 27 days to avoid calendar-month truncation, including around February and partial days. Deployments reject combinations requiring more than 30 minutes of *minimum* estimated request pacing: `accounts x ceil(lookback_days / 27) x 2 x 16 seconds`. At the 90-day default this permits at most 14 accounts per stack. Pagination and retries can take longer, and the Function has a 55-minute execution timeout. Split larger estates or reduce the lookback.

Each successful run appends a snapshot. A completion marker is written only after all data has been submitted, and the dashboard waits until the expected distinct row count is queryable. Failed or partially ingested runs are ignored; the next scheduled run starts over. The dashboard searches for completed snapshots from the last 14 days, flags those older than 48 hours as stale, and warns when the selected period is outside the collected window. No reported rows means **no cost data reported**, not zero cost.

The workspace's retention and daily ingestion cap apply to these records. Snapshot copies, queries, storage, Function execution, Grafana, and alerts can incur charges. The deployment storage account enables seven-day soft delete for blobs and containers; deleted deployment packages remain recoverable during that window and can incur storage charges. Blob `StorageRead` diagnostics are sent to the monitoring workspace and can incur Log Analytics ingestion and retention charges. The Function and storage use public endpoints protected by Entra authorization; private networking requires a separate design.

## Troubleshooting

If the dashboard reports a missing or stale snapshot, check the Function invocation and Application Insights logs, subscription Cost Management Reader, data collection rule publishing role, network access, workspace cap, and actual billing availability. Azure role propagation can delay the first successful collection. A collector-failure alert is not provisioned automatically. Do not interpret a missing snapshot as zero spend.
