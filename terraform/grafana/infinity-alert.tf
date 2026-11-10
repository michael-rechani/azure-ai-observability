# This resource is in its own file because the Grafana provider requires an attribute named `for` on the rule,
# and checkov's HCL parser (bc-python-hcl2) cannot parse a `for` attribute. The Security workflow fails the
# scan on any parse error, so it passes `--skip-path` for this one file. Keep only this resource here; the rest
# of the alert (locals and the folder) stays in main.tf, where checkov still reads it. Trivy still scans this file.

# The rule's condition can never be true. It exists to fail when the data source cannot query Cost Management
# (expired, revoked or wrong client secret; lost role), and exec_err_state turns that failure into an alert.
resource "grafana_rule_group" "infinity_alert" {
  count            = local.infinity_alert_enabled ? 1 : 0
  name             = "Infinity cost data source"
  folder_uid       = grafana_folder.infinity_alert[0].uid
  interval_seconds = var.cost_infinity_alert_interval_minutes * 60

  rule {
    name           = "Infinity cost data source cannot query Cost Management"
    condition      = "C"
    for            = "${var.cost_infinity_alert_pending_minutes}m"
    no_data_state  = "OK"
    exec_err_state = "Alerting"
    labels = {
      component  = "cost-infinity"
      severity   = "warning"
      managed_by = "azure-ai-observability-terraform"
    }
    annotations = {
      summary     = "The AI observability cost panels cannot reach Cost Management"
      description = "The Infinity data source's Cost Management query failed. The usual cause is an expired, revoked or wrong service principal client secret (AADSTS7000215 or AADSTS7000222), or a removed Cost Management role. Rotate the secret as described in docs/costs.md. Grafana caches the access token, so a secret that has just expired can take up to an hour to surface."
    }

    data {
      ref_id         = "A"
      datasource_uid = grafana_data_source.infinity[0].uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode(merge(local.infinity_alert_target, {
        refId         = "A"
        datasource    = { type = "yesoreyeram-infinity-datasource", uid = grafana_data_source.infinity[0].uid }
        url           = replace(local.infinity_alert_target.url, "$${costScope}", local.infinity_alert_scope)
        root_selector = "if .properties.rows then [{rows: (.properties.rows | length)}] else error(\"no_cost_rows_property\") end"
        columns       = [{ selector = "rows", text = "rows", type = "number" }]
        intervalMs    = 1000
        maxDataPoints = 43200
      }))
    }

    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        refId      = "B"
        type       = "reduce"
        datasource = { type = "__expr__", uid = "__expr__" }
        expression = "A"
        reducer    = "count"
        settings   = { mode = "dropNN" }
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        datasource = { type = "__expr__", uid = "__expr__" }
        expression = "B"
        conditions = [{ evaluator = { type = "gt", params = [1000000000] } }]
      })
    }
  }
}
