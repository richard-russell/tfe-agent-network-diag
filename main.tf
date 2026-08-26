# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0
#
# Network diagnostics — runs inside a TFE agent pod to prove CoreDNS rewrite
# and in-cluster connectivity to the TFE service are working correctly.
#
# Usage:
#   1. Create a TFE workspace backed by this directory, using an agent pool
#      assigned to the tfe-agents namespace on this cluster.
#   2. Trigger a plan. All diagnostics run during the plan via data sources.
#   3. Review the outputs.

variable "tfe_fqdn" {
  type        = string
  description = "External TFE FQDN (e.g. eks-tfe.example.com). Should resolve to the internal ClusterIP after CoreDNS rewrite."
}

variable "tfe_internal_svc" {
  type        = string
  description = "Internal Kubernetes service DNS name for TFE."
  default     = "terraform-enterprise.tfe.svc.cluster.local"
}

locals {
  tfe_https_url      = "https://${var.tfe_fqdn}"
  tfe_internal_https = "https://${var.tfe_internal_svc}"
  health_path        = "/api/v1/health/readiness?timeout=5"
}

# --- DNS resolution via nslookup --- #

data "external" "dns_fqdn" {
  program = ["sh", "-c", <<-EOT
    result=$(nslookup "${var.tfe_fqdn}" 2>&1 || true)
    echo "{\"result\": $(echo "$result" | tr '\n' '|' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

data "external" "dns_internal" {
  program = ["sh", "-c", <<-EOT
    result=$(nslookup "${var.tfe_internal_svc}" 2>&1 || true)
    echo "{\"result\": $(echo "$result" | tr '\n' '|' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

# --- Confirm fqdn and internal svc resolve to same IP (proves CoreDNS rewrite) --- #

data "external" "dns_rewrite_check" {
  program = ["sh", "-c", <<-EOT
    fqdn_ip=$(nslookup "${var.tfe_fqdn}" 2>/dev/null | awk '/^Address: /{print $2}' | grep -v '#' | head -1)
    svc_ip=$(nslookup "${var.tfe_internal_svc}" 2>/dev/null | awk '/^Address: /{print $2}' | grep -v '#' | head -1)
    if [ "$fqdn_ip" = "$svc_ip" ] && [ -n "$fqdn_ip" ]; then
      match="true"
    else
      match="false"
    fi
    echo "{\"fqdn_resolves_to\": \"$fqdn_ip\", \"internal_svc_resolves_to\": \"$svc_ip\", \"ips_match\": \"$match\"}"
  EOT
  ]
}

# --- TCP reachability on port 443 via curl connect-only --- #

data "external" "tcp_fqdn_443" {
  program = ["sh", "-c", <<-EOT
    result=$(curl -sk --connect-timeout 5 -o /dev/null -w "%%{http_code}" "${local.tfe_https_url}" 2>&1 || echo "failed")
    echo "{\"result\": \"$result\"}"
  EOT
  ]
}

data "external" "tcp_internal_443" {
  program = ["sh", "-c", <<-EOT
    result=$(curl -sk --connect-timeout 5 -o /dev/null -w "%%{http_code}" "${local.tfe_internal_https}" 2>&1 || echo "failed")
    echo "{\"result\": \"$result\"}"
  EOT
  ]
}

# --- TLS certificate details via curl --- #

data "external" "tls_cert_check" {
  program = ["sh", "-c", <<-EOT
    result=$(curl -svk --connect-timeout 5 -o /dev/null "${local.tfe_https_url}" 2>&1 | grep -E "subject:|issuer:|expire date:|start date:|SSL connection" | tr '\n' '|' || echo "failed")
    echo "{\"result\": $(echo "$result" | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

# --- HTTP health check via FQDN (goes through CoreDNS rewrite → ClusterIP) --- #

data "external" "health_fqdn" {
  program = ["sh", "-c", <<-EOT
    result=$(curl -sk --max-time 10 -o /dev/null -w "%%{http_code}" "${local.tfe_https_url}${local.health_path}" 2>&1 || echo "failed")
    echo "{\"http_code\": \"$result\"}"
  EOT
  ]
}

# --- HTTP health check via internal svc DNS directly --- #

data "external" "health_internal" {
  program = ["sh", "-c", <<-EOT
    result=$(curl -sk --max-time 10 -o /dev/null -w "%%{http_code}" "${local.tfe_internal_https}${local.health_path}" 2>&1 || echo "failed")
    echo "{\"http_code\": \"$result\"}"
  EOT
  ]
}

# --- Route check: how many hops to FQDN vs internal svc (using curl timing) --- #

data "external" "curl_timing_fqdn" {
  program = ["sh", "-c", <<-EOT
    result=$(curl -sk --max-time 10 -o /dev/null \
      -w "http_code=%%{http_code} time_namelookup=%%{time_namelookup} time_connect=%%{time_connect} time_total=%%{time_total} remote_ip=%%{remote_ip}" \
      "${local.tfe_https_url}" 2>&1 || echo "failed")
    echo "{\"result\": $(echo "$result" | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

data "external" "curl_timing_internal" {
  program = ["sh", "-c", <<-EOT
    result=$(curl -sk --max-time 10 -o /dev/null \
      -w "http_code=%%{http_code} time_namelookup=%%{time_namelookup} time_connect=%%{time_connect} time_total=%%{time_total} remote_ip=%%{remote_ip}" \
      "${local.tfe_internal_https}" 2>&1 || echo "failed")
    echo "{\"result\": $(echo "$result" | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}
