# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "dns_fqdn_resolution" {
  description = "nslookup output for the external TFE FQDN. After CoreDNS rewrite, should return the ClusterIP."
  value       = data.external.dns_fqdn.result["result"]
}

output "dns_internal_svc_resolution" {
  description = "nslookup output for the internal Kubernetes service DNS name."
  value       = data.external.dns_internal.result["result"]
}

output "coredns_rewrite_verified" {
  description = "Whether the external FQDN and internal service name resolve to the same IP, confirming the CoreDNS rewrite is active."
  value = {
    fqdn_resolves_to         = data.external.dns_rewrite_check.result["fqdn_resolves_to"]
    internal_svc_resolves_to = data.external.dns_rewrite_check.result["internal_svc_resolves_to"]
    ips_match                = data.external.dns_rewrite_check.result["ips_match"]
  }
}

output "tcp_port_443_fqdn" {
  description = "HTTP response code from a curl connect to port 443 via the external FQDN. Non-empty = TCP is open."
  value       = data.external.tcp_fqdn_443.result["result"]
}

output "tcp_port_443_internal_svc" {
  description = "HTTP response code from a curl connect to port 443 via the internal service DNS name."
  value       = data.external.tcp_internal_443.result["result"]
}

output "tls_certificate" {
  description = "TLS certificate details (subject, issuer, validity dates) for the TFE endpoint, extracted from curl verbose output."
  value       = data.external.tls_cert_check.result["result"]
}

output "health_check_via_fqdn" {
  description = "HTTP response code from the TFE readiness endpoint via the external FQDN. Expects 200 once CoreDNS rewrite is active."
  value       = data.external.health_fqdn.result["http_code"]
}

output "health_check_via_internal_svc" {
  description = "HTTP response code from the TFE readiness endpoint via the internal service DNS name directly. Expects 200."
  value       = data.external.health_internal.result["http_code"]
}

output "curl_timing_fqdn" {
  description = "curl timing and remote_ip for the external FQDN. If CoreDNS rewrite is working, remote_ip should be the ClusterIP (172.20.x.x), not an NLB IP. time_connect should be sub-millisecond."
  value       = data.external.curl_timing_fqdn.result["result"]
}

output "curl_timing_internal_svc" {
  description = "curl timing and remote_ip for the internal service DNS name directly."
  value       = data.external.curl_timing_internal.result["result"]
}
