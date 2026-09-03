# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "dns_config" {
  description = "Contents of /etc/resolv.conf in the agent pod — shows which DNS server is being used and the search domains."
  value       = data.external.dns_config.result["resolv_conf"]
}

output "internet_egress" {
  description = "curl to https://www.google.com. Confirms whether the agent pod has outbound internet access and external DNS resolution."
  value       = data.external.internet_egress.result["result"]
}

output "dns_fqdn_resolution" {
  description = "nslookup output for the external TFE FQDN. After CoreDNS rewrite, should return the ClusterIP."
  value       = data.external.dns_fqdn.result["result"]
}

output "dns_internal_svc_resolution" {
  description = "nslookup output for the internal Kubernetes service DNS name."
  value       = data.external.dns_internal.result["result"]
}

output "getent_fqdn" {
  description = "getent hosts output for the external FQDN. Uses system NSS resolver — most accurate reflection of what the CoreDNS rewrite produces."
  value       = data.external.getent_fqdn.result["result"]
}

output "getent_internal_svc" {
  description = "getent hosts output for the internal Kubernetes service DNS name."
  value       = data.external.getent_internal.result["result"]
}

output "hairpin_routing_active" {
  description = "Whether the external FQDN and internal service name resolve to the same IP. true = hairpin fix is working (CoreDNS rewrite or hostAliases), false = FQDN is routing via the external NLB."
  value = {
    fqdn_resolves_to         = data.external.dns_rewrite_check.result["fqdn_resolves_to"]
    internal_svc_resolves_to = data.external.dns_rewrite_check.result["internal_svc_resolves_to"]
    ips_match                = data.external.dns_rewrite_check.result["ips_match"]
  }
}

output "tls_certificate" {
  description = "TLS certificate details (subject, issuer, validity dates, SANs) from openssl s_client."
  value       = data.external.tls_cert_check.result["result"]
}

locals {
  probe_fields = ["http_code", "remote_ip", "time_namelookup", "time_connect", "time_total", "redirect_location"]
}

output "probe_fqdn_root_insecure" {
  description = "FQDN / root path / TLS skip. Expects http_code=301, remote_ip=NLB IP at baseline; remote_ip=ClusterIP after hairpin fix."
  value       = { for k in local.probe_fields : k => data.external.probe_fqdn_root_insecure.result[k] }
}

output "probe_fqdn_root_secure" {
  description = "FQDN / root path / strict TLS. Expects http_code=301 if the TFE cert is valid and trusted by the agent pod's CA bundle."
  value       = { for k in local.probe_fields : k => data.external.probe_fqdn_root_secure.result[k] }
}

output "probe_fqdn_health_insecure" {
  description = "FQDN / /api/v2/ping / TLS skip. Expects http_code=200, remote_ip=NLB IP at baseline; remote_ip=ClusterIP after hairpin fix."
  value       = { for k in local.probe_fields : k => data.external.probe_fqdn_health_insecure.result[k] }
}

output "probe_fqdn_health_secure" {
  description = "FQDN / /api/v2/ping / strict TLS. Expects http_code=200 if the TFE cert is valid and trusted."
  value       = { for k in local.probe_fields : k => data.external.probe_fqdn_health_secure.result[k] }
}

output "probe_internal_root_insecure" {
  description = "Internal svc / root path / TLS skip. Expects http_code=301, remote_ip=ClusterIP."
  value       = { for k in local.probe_fields : k => data.external.probe_internal_root_insecure.result[k] }
}

output "probe_internal_root_secure" {
  description = "Internal svc / root path / strict TLS. Expects http_code=000 — cert CN is the external FQDN, not the internal svc name."
  value       = { for k in local.probe_fields : k => data.external.probe_internal_root_secure.result[k] }
}

output "probe_internal_health_insecure" {
  description = "Internal svc / /api/v2/ping / TLS skip. Expects http_code=200, remote_ip=ClusterIP."
  value       = { for k in local.probe_fields : k => data.external.probe_internal_health_insecure.result[k] }
}

output "probe_internal_health_secure" {
  description = "Internal svc / /api/v2/ping / strict TLS. Expects http_code=000 — cert CN mismatch on internal svc hostname."
  value       = { for k in local.probe_fields : k => data.external.probe_internal_health_secure.result[k] }
}

