terraform {
  required_version = ">= 1.7.0, < 2.0.0"
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
  }
}

provider "grafana" {
  url = var.grafana_endpoint
}
