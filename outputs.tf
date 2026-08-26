# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "dns_fqdn_resolution" {
  description = "Raw dig output for the external TFE FQDN. Should return the ClusterIP after CoreDNS rewrite is applied."
  value       = data.external.dns_fqdn.result["result"]
}

output "dns_internal_svc_resolution" {
  description = "Raw dig output for the internal Kubernetes service DNS name."
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
  description = "TCP reachability on port 443 via the external FQDN (routed via CoreDNS rewrite)."
  value = {
    status = data.external.tcp_fqdn_443.result["status"]
    detail = data.external.tcp_fqdn_443.result["detail"]
  }
}

output "tcp_port_443_internal_svc" {
  description = "TCP reachability on port 443 via the internal Kubernetes service DNS name directly."
  value = {
    status = data.external.tcp_internal_443.result["status"]
    detail = data.external.tcp_internal_443.result["detail"]
  }
}

output "tls_certificate" {
  description = "TLS certificate details (subject, issuer, validity dates, SANs) for the TFE endpoint."
  value       = data.external.tls_cert_check.result["result"]
}

output "health_check_via_fqdn" {
  description = "HTTP response code from the TFE readiness endpoint via the external FQDN. Expects 200."
  value       = data.external.health_fqdn.result["http_code"]
}

output "health_check_via_internal_svc" {
  description = "HTTP response code from the TFE readiness endpoint via the internal service DNS name directly. Expects 200."
  value       = data.external.health_internal.result["http_code"]
}

output "traceroute_to_fqdn" {
  description = "Traceroute to the external FQDN. If CoreDNS rewrite is working, traffic should reach the destination in 1 hop (ClusterIP, no external routing)."
  value       = data.external.traceroute_fqdn.result["result"]
}
