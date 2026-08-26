# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "tool_install_status" {
  description = "Exit code and full apt-get log from the tool install step."
  value = {
    status = data.external.install_tools.result["status"]
    log    = data.external.install_tools.result["log"]
  }
}

output "dns_fqdn_resolution" {
  description = "dig output for the external TFE FQDN. After CoreDNS rewrite, should return the ClusterIP."
  value       = data.external.dns_fqdn.result["result"]
}

output "dns_internal_svc_resolution" {
  description = "dig output for the internal Kubernetes service DNS name."
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
  description = "nc TCP probe on port 443 via the external FQDN."
  value = {
    status = data.external.tcp_fqdn_443.result["status"]
    detail = data.external.tcp_fqdn_443.result["detail"]
  }
}

output "tcp_port_443_internal_svc" {
  description = "nc TCP probe on port 443 via the internal Kubernetes service DNS name."
  value = {
    status = data.external.tcp_internal_443.result["status"]
    detail = data.external.tcp_internal_443.result["detail"]
  }
}

output "tls_certificate" {
  description = "TLS certificate details (subject, issuer, validity dates, SANs) from openssl s_client."
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
  description = "curl timing and remote_ip for the external FQDN. If CoreDNS rewrite is working, remote_ip should be the ClusterIP (172.20.x.x). time_connect should be sub-millisecond."
  value       = data.external.curl_timing_fqdn.result["result"]
}

output "curl_timing_internal_svc" {
  description = "curl timing and remote_ip for the internal service DNS name directly."
  value       = data.external.curl_timing_internal.result["result"]
}

output "traceroute_to_fqdn" {
  description = "Traceroute to the external FQDN (max 5 hops). If CoreDNS rewrite is working, traffic should arrive in 1 hop via the ClusterIP."
  value       = data.external.traceroute_fqdn.result["result"]
}
