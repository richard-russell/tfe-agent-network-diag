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
  # Sentinel value consumed by depends_on to gate all diagnostics on tool install
  tools_installed = data.external.install_tools.result["status"]
}

# --- Install diagnostic tools (via sudo apt-get) --- #

data "external" "install_tools" {
  program = ["sh", "-c", <<-EOT
    whoami=$(whoami 2>/dev/null || echo "unknown")
    sudo_available=$(command -v sudo 2>/dev/null || echo "")
    DEBIAN_FRONTEND=noninteractive sudo -n apt-get install -y -qq dnsutils netcat-openbsd traceroute >/tmp/apt-install.log 2>&1
    exit_code=$?
    log=$(cat /tmp/apt-install.log | tr '\n' '|' | sed 's/"/\\"/g')
    echo "{\"status\": \"exit_code=$exit_code\", \"log\": \"whoami=$whoami sudo=$sudo_available apt=$log\"}"
  EOT
  ]
}

# --- DNS resolution via dig --- #

data "external" "dns_fqdn" {
  depends_on = [data.external.install_tools]
  program = ["sh", "-c", <<-EOT
    result=$(dig +short +time=5 +tries=1 "${var.tfe_fqdn}" 2>&1 || true)
    echo "{\"result\": $(echo "$result" | tr '\n' '|' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

data "external" "dns_internal" {
  depends_on = [data.external.install_tools]
  program = ["sh", "-c", <<-EOT
    result=$(dig +short +time=5 +tries=1 "${var.tfe_internal_svc}" 2>&1 || true)
    echo "{\"result\": $(echo "$result" | tr '\n' '|' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

# --- Confirm fqdn and internal svc resolve to same IP (proves CoreDNS rewrite) --- #

data "external" "dns_rewrite_check" {
  depends_on = [data.external.install_tools]
  program = ["sh", "-c", <<-EOT
    fqdn_ip=$(dig +short +time=5 +tries=1 "${var.tfe_fqdn}" | grep -E '^[0-9]+\.' | head -1)
    svc_ip=$(dig +short +time=5 +tries=1 "${var.tfe_internal_svc}" | grep -E '^[0-9]+\.' | head -1)
    if [ "$fqdn_ip" = "$svc_ip" ] && [ -n "$fqdn_ip" ]; then
      match="true"
    else
      match="false"
    fi
    echo "{\"fqdn_resolves_to\": \"$fqdn_ip\", \"internal_svc_resolves_to\": \"$svc_ip\", \"ips_match\": \"$match\"}"
  EOT
  ]
}

# --- TCP reachability on port 443 via nc --- #

data "external" "tcp_fqdn_443" {
  depends_on = [data.external.install_tools]
  program = ["sh", "-c", <<-EOT
    result=$(nc -zv -w5 "${var.tfe_fqdn}" 443 2>&1 || true)
    status=$(echo "$result" | grep -qi "succeeded\|open\|Connected" && echo "open" || echo "failed")
    echo "{\"status\": \"$status\", \"detail\": $(echo "$result" | tr '\n' ' ' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

data "external" "tcp_internal_443" {
  depends_on = [data.external.install_tools]
  program = ["sh", "-c", <<-EOT
    result=$(nc -zv -w5 "${var.tfe_internal_svc}" 443 2>&1 || true)
    status=$(echo "$result" | grep -qi "succeeded\|open\|Connected" && echo "open" || echo "failed")
    echo "{\"status\": \"$status\", \"detail\": $(echo "$result" | tr '\n' ' ' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

# --- TLS certificate details via openssl --- #

data "external" "tls_cert_check" {
  depends_on = [data.external.install_tools]
  program = ["sh", "-c", <<-EOT
    result=$(echo | openssl s_client -connect "${var.tfe_fqdn}:443" -servername "${var.tfe_fqdn}" 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || echo "failed")
    echo "{\"result\": $(echo "$result" | tr '\n' '|' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
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

# --- curl timing: remote_ip confirms whether traffic is hitting ClusterIP or NLB --- #

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

# --- Ping: round-trip time confirms in-cluster vs external routing --- #

data "external" "ping_fqdn" {
  program = ["sh", "-c", <<-EOT
    result=$(ping -c 4 -W 2 "${var.tfe_fqdn}" 2>&1 || true)
    echo "{\"result\": $(echo "$result" | tr '\n' '|' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

data "external" "ping_internal" {
  program = ["sh", "-c", <<-EOT
    result=$(ping -c 4 -W 2 "${var.tfe_internal_svc}" 2>&1 || true)
    echo "{\"result\": $(echo "$result" | tr '\n' '|' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

# --- Traceroute to FQDN: 1 hop = in-cluster (ClusterIP); multiple hops = going via NLB --- #

data "external" "traceroute_fqdn" {
  depends_on = [data.external.install_tools]
  program = ["sh", "-c", <<-EOT
    result=$(traceroute -n -m 5 -w 2 "${var.tfe_fqdn}" 2>&1 || true)
    echo "{\"result\": $(echo "$result" | tr '\n' '|' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}
