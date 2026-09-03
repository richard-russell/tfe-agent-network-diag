# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0
#
# Network diagnostics — runs inside a TFE agent pod to diagnose connectivity
# and hairpin routing between agent pods and the TFE service.
#
# Runs as user 'tfc-agent' (non-root, no sudo, no package manager access).
# Available tools: curl, openssl, awk, grep, sed, ping.
#
# Usage:
#   1. Create a TFE workspace backed by this directory, using an agent pool
#      assigned to the tfe-agents namespace on this cluster.
#   2. Trigger a plan. All diagnostics run during the plan via data sources.
#   3. Review the outputs.

variable "tfe_fqdn" {
  type        = string
  description = "External TFE FQDN (e.g. eks-tfe.example.com)."
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

# --- DNS resolution via nslookup and getent --- #

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

# getent uses the system NSS resolver — reflects CoreDNS rewrite via /etc/resolv.conf
data "external" "getent_fqdn" {
  program = ["sh", "-c", <<-EOT
    result=$(getent hosts "${var.tfe_fqdn}" 2>&1 || echo "not found")
    echo "{\"result\": \"$result\"}"
  EOT
  ]
}

data "external" "getent_internal" {
  program = ["sh", "-c", <<-EOT
    result=$(getent hosts "${var.tfe_internal_svc}" 2>&1 || echo "not found")
    echo "{\"result\": \"$result\"}"
  EOT
  ]
}

# --- Confirm fqdn and internal svc resolve to same IP (proves CoreDNS rewrite) --- #

data "external" "dns_rewrite_check" {
  program = ["sh", "-c", <<-EOT
    fqdn_ip=$(getent hosts "${var.tfe_fqdn}" 2>/dev/null | awk '{print $1}' | head -1)
    svc_ip=$(getent hosts "${var.tfe_internal_svc}" 2>/dev/null | awk '{print $1}' | head -1)
    if [ "$fqdn_ip" = "$svc_ip" ] && [ -n "$fqdn_ip" ]; then
      match="true"
    else
      match="false"
    fi
    echo "{\"fqdn_resolves_to\": \"$fqdn_ip\", \"internal_svc_resolves_to\": \"$svc_ip\", \"ips_match\": \"$match\"}"
  EOT
  ]
}

# --- TLS certificate details via openssl --- #

data "external" "tls_cert_check" {
  program = ["sh", "-c", <<-EOT
    result=$(echo | openssl s_client -connect "${var.tfe_fqdn}:443" -servername "${var.tfe_fqdn}" 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || echo "failed")
    echo "{\"result\": $(echo "$result" | tr '\n' '|' | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

# --- HTTP probes: 4 per target (2 paths × 2 TLS modes) --- #
#
# Every probe emits: http_code, remote_ip, time_namelookup, time_connect,
# time_total, redirect_location.
#
# --max-redirs 0: never follow redirects — 301s surface as-is.
# -D /tmp/hdrs_<suffix>: dump response headers to extract Location header
#   without a second curl call. Unique suffix per probe avoids file collisions
#   when Terraform evaluates data sources concurrently.
# Insecure probes: -sk (skip TLS verify)
# Secure probes:   -s  (strict TLS verify — will fail on CN mismatch)

locals {
  curl_w = "http_code=%%{http_code} remote_ip=%%{remote_ip} time_namelookup=%%{time_namelookup} time_connect=%%{time_connect} time_total=%%{time_total}"
}

data "external" "probe_fqdn_root_insecure" {
  program = ["sh", "-c", <<-EOT
    curl -sk --max-redirs 0 --max-time 10 -o /dev/null -D /tmp/hdrs_fri \
      -w "${local.curl_w}" \
      "${local.tfe_https_url}/" > /tmp/res_fri 2>/dev/null || echo "failed" > /tmp/res_fri
    result=$(cat /tmp/res_fri)
    location=$(grep -i "^location:" /tmp/hdrs_fri 2>/dev/null | tr -d '\r' | sed 's/^[Ll]ocation: //' || echo "")
    http_code=$(echo "$result" | grep -o 'http_code=[^ ]*' | cut -d= -f2)
    remote_ip=$(echo "$result" | grep -o 'remote_ip=[^ ]*' | cut -d= -f2)
    time_namelookup=$(echo "$result" | grep -o 'time_namelookup=[^ ]*' | cut -d= -f2)
    time_connect=$(echo "$result" | grep -o 'time_connect=[^ ]*' | cut -d= -f2)
    time_total=$(echo "$result" | grep -o 'time_total=[^ ]*' | cut -d= -f2)
    echo "{\"http_code\":\"$http_code\",\"remote_ip\":\"$remote_ip\",\"time_namelookup\":\"$time_namelookup\",\"time_connect\":\"$time_connect\",\"time_total\":\"$time_total\",\"redirect_location\":\"$location\"}"
  EOT
  ]
}

data "external" "probe_fqdn_root_secure" {
  program = ["sh", "-c", <<-EOT
    curl -s --max-redirs 0 --max-time 10 -o /dev/null -D /tmp/hdrs_frs \
      -w "${local.curl_w}" \
      "${local.tfe_https_url}/" > /tmp/res_frs 2>/dev/null || echo "failed" > /tmp/res_frs
    result=$(cat /tmp/res_frs)
    location=$(grep -i "^location:" /tmp/hdrs_frs 2>/dev/null | tr -d '\r' | sed 's/^[Ll]ocation: //' || echo "")
    http_code=$(echo "$result" | grep -o 'http_code=[^ ]*' | cut -d= -f2)
    remote_ip=$(echo "$result" | grep -o 'remote_ip=[^ ]*' | cut -d= -f2)
    time_namelookup=$(echo "$result" | grep -o 'time_namelookup=[^ ]*' | cut -d= -f2)
    time_connect=$(echo "$result" | grep -o 'time_connect=[^ ]*' | cut -d= -f2)
    time_total=$(echo "$result" | grep -o 'time_total=[^ ]*' | cut -d= -f2)
    echo "{\"http_code\":\"$http_code\",\"remote_ip\":\"$remote_ip\",\"time_namelookup\":\"$time_namelookup\",\"time_connect\":\"$time_connect\",\"time_total\":\"$time_total\",\"redirect_location\":\"$location\"}"
  EOT
  ]
}

data "external" "probe_fqdn_health_insecure" {
  program = ["sh", "-c", <<-EOT
    curl -sk --max-redirs 0 --max-time 10 -o /dev/null -D /tmp/hdrs_fhi \
      -w "${local.curl_w}" \
      "${local.tfe_https_url}${local.health_path}" > /tmp/res_fhi 2>/dev/null || echo "failed" > /tmp/res_fhi
    result=$(cat /tmp/res_fhi)
    location=$(grep -i "^location:" /tmp/hdrs_fhi 2>/dev/null | tr -d '\r' | sed 's/^[Ll]ocation: //' || echo "")
    http_code=$(echo "$result" | grep -o 'http_code=[^ ]*' | cut -d= -f2)
    remote_ip=$(echo "$result" | grep -o 'remote_ip=[^ ]*' | cut -d= -f2)
    time_namelookup=$(echo "$result" | grep -o 'time_namelookup=[^ ]*' | cut -d= -f2)
    time_connect=$(echo "$result" | grep -o 'time_connect=[^ ]*' | cut -d= -f2)
    time_total=$(echo "$result" | grep -o 'time_total=[^ ]*' | cut -d= -f2)
    echo "{\"http_code\":\"$http_code\",\"remote_ip\":\"$remote_ip\",\"time_namelookup\":\"$time_namelookup\",\"time_connect\":\"$time_connect\",\"time_total\":\"$time_total\",\"redirect_location\":\"$location\"}"
  EOT
  ]
}

data "external" "probe_fqdn_health_secure" {
  program = ["sh", "-c", <<-EOT
    curl -s --max-redirs 0 --max-time 10 -o /dev/null -D /tmp/hdrs_fhs \
      -w "${local.curl_w}" \
      "${local.tfe_https_url}${local.health_path}" > /tmp/res_fhs 2>/dev/null || echo "failed" > /tmp/res_fhs
    result=$(cat /tmp/res_fhs)
    location=$(grep -i "^location:" /tmp/hdrs_fhs 2>/dev/null | tr -d '\r' | sed 's/^[Ll]ocation: //' || echo "")
    http_code=$(echo "$result" | grep -o 'http_code=[^ ]*' | cut -d= -f2)
    remote_ip=$(echo "$result" | grep -o 'remote_ip=[^ ]*' | cut -d= -f2)
    time_namelookup=$(echo "$result" | grep -o 'time_namelookup=[^ ]*' | cut -d= -f2)
    time_connect=$(echo "$result" | grep -o 'time_connect=[^ ]*' | cut -d= -f2)
    time_total=$(echo "$result" | grep -o 'time_total=[^ ]*' | cut -d= -f2)
    echo "{\"http_code\":\"$http_code\",\"remote_ip\":\"$remote_ip\",\"time_namelookup\":\"$time_namelookup\",\"time_connect\":\"$time_connect\",\"time_total\":\"$time_total\",\"redirect_location\":\"$location\"}"
  EOT
  ]
}

data "external" "probe_internal_root_insecure" {
  program = ["sh", "-c", <<-EOT
    curl -sk --max-redirs 0 --max-time 10 -o /dev/null -D /tmp/hdrs_iri \
      -w "${local.curl_w}" \
      "${local.tfe_internal_https}/" > /tmp/res_iri 2>/dev/null || echo "failed" > /tmp/res_iri
    result=$(cat /tmp/res_iri)
    location=$(grep -i "^location:" /tmp/hdrs_iri 2>/dev/null | tr -d '\r' | sed 's/^[Ll]ocation: //' || echo "")
    http_code=$(echo "$result" | grep -o 'http_code=[^ ]*' | cut -d= -f2)
    remote_ip=$(echo "$result" | grep -o 'remote_ip=[^ ]*' | cut -d= -f2)
    time_namelookup=$(echo "$result" | grep -o 'time_namelookup=[^ ]*' | cut -d= -f2)
    time_connect=$(echo "$result" | grep -o 'time_connect=[^ ]*' | cut -d= -f2)
    time_total=$(echo "$result" | grep -o 'time_total=[^ ]*' | cut -d= -f2)
    echo "{\"http_code\":\"$http_code\",\"remote_ip\":\"$remote_ip\",\"time_namelookup\":\"$time_namelookup\",\"time_connect\":\"$time_connect\",\"time_total\":\"$time_total\",\"redirect_location\":\"$location\"}"
  EOT
  ]
}

data "external" "probe_internal_root_secure" {
  program = ["sh", "-c", <<-EOT
    curl -s --max-redirs 0 --max-time 10 -o /dev/null -D /tmp/hdrs_irs \
      -w "${local.curl_w}" \
      "${local.tfe_internal_https}/" > /tmp/res_irs 2>/dev/null || echo "failed" > /tmp/res_irs
    result=$(cat /tmp/res_irs)
    location=$(grep -i "^location:" /tmp/hdrs_irs 2>/dev/null | tr -d '\r' | sed 's/^[Ll]ocation: //' || echo "")
    http_code=$(echo "$result" | grep -o 'http_code=[^ ]*' | cut -d= -f2)
    remote_ip=$(echo "$result" | grep -o 'remote_ip=[^ ]*' | cut -d= -f2)
    time_namelookup=$(echo "$result" | grep -o 'time_namelookup=[^ ]*' | cut -d= -f2)
    time_connect=$(echo "$result" | grep -o 'time_connect=[^ ]*' | cut -d= -f2)
    time_total=$(echo "$result" | grep -o 'time_total=[^ ]*' | cut -d= -f2)
    echo "{\"http_code\":\"$http_code\",\"remote_ip\":\"$remote_ip\",\"time_namelookup\":\"$time_namelookup\",\"time_connect\":\"$time_connect\",\"time_total\":\"$time_total\",\"redirect_location\":\"$location\"}"
  EOT
  ]
}

data "external" "probe_internal_health_insecure" {
  program = ["sh", "-c", <<-EOT
    curl -sk --max-redirs 0 --max-time 10 -o /dev/null -D /tmp/hdrs_ihi \
      -w "${local.curl_w}" \
      "${local.tfe_internal_https}${local.health_path}" > /tmp/res_ihi 2>/dev/null || echo "failed" > /tmp/res_ihi
    result=$(cat /tmp/res_ihi)
    location=$(grep -i "^location:" /tmp/hdrs_ihi 2>/dev/null | tr -d '\r' | sed 's/^[Ll]ocation: //' || echo "")
    http_code=$(echo "$result" | grep -o 'http_code=[^ ]*' | cut -d= -f2)
    remote_ip=$(echo "$result" | grep -o 'remote_ip=[^ ]*' | cut -d= -f2)
    time_namelookup=$(echo "$result" | grep -o 'time_namelookup=[^ ]*' | cut -d= -f2)
    time_connect=$(echo "$result" | grep -o 'time_connect=[^ ]*' | cut -d= -f2)
    time_total=$(echo "$result" | grep -o 'time_total=[^ ]*' | cut -d= -f2)
    echo "{\"http_code\":\"$http_code\",\"remote_ip\":\"$remote_ip\",\"time_namelookup\":\"$time_namelookup\",\"time_connect\":\"$time_connect\",\"time_total\":\"$time_total\",\"redirect_location\":\"$location\"}"
  EOT
  ]
}

data "external" "probe_internal_health_secure" {
  program = ["sh", "-c", <<-EOT
    curl -s --max-redirs 0 --max-time 10 -o /dev/null -D /tmp/hdrs_ihs \
      -w "${local.curl_w}" \
      "${local.tfe_internal_https}${local.health_path}" > /tmp/res_ihs 2>/dev/null || echo "failed" > /tmp/res_ihs
    result=$(cat /tmp/res_ihs)
    location=$(grep -i "^location:" /tmp/hdrs_ihs 2>/dev/null | tr -d '\r' | sed 's/^[Ll]ocation: //' || echo "")
    http_code=$(echo "$result" | grep -o 'http_code=[^ ]*' | cut -d= -f2)
    remote_ip=$(echo "$result" | grep -o 'remote_ip=[^ ]*' | cut -d= -f2)
    time_namelookup=$(echo "$result" | grep -o 'time_namelookup=[^ ]*' | cut -d= -f2)
    time_connect=$(echo "$result" | grep -o 'time_connect=[^ ]*' | cut -d= -f2)
    time_total=$(echo "$result" | grep -o 'time_total=[^ ]*' | cut -d= -f2)
    echo "{\"http_code\":\"$http_code\",\"remote_ip\":\"$remote_ip\",\"time_namelookup\":\"$time_namelookup\",\"time_connect\":\"$time_connect\",\"time_total\":\"$time_total\",\"redirect_location\":\"$location\"}"
  EOT
  ]
}

# --- DNS configuration in the agent pod --- #

data "external" "dns_config" {
  program = ["sh", "-c", <<-EOT
    resolv=$(cat /etc/resolv.conf 2>/dev/null | tr '\n' '|' | sed 's/"/\\"/g')
    echo "{\"resolv_conf\": \"$resolv\"}"
  EOT
  ]
}

# --- Internet egress check --- #

data "external" "internet_egress" {
  program = ["sh", "-c", <<-EOT
    result=$(curl -sk --max-time 10 -o /dev/null \
      -w "http_code=%%{http_code} time_namelookup=%%{time_namelookup} time_connect=%%{time_connect} remote_ip=%%{remote_ip}" \
      "https://www.google.com" 2>&1 || echo "failed")
    echo "{\"result\": $(echo "$result" | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}')}"
  EOT
  ]
}

