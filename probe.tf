# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0
#
# Probe: detect OS and available package manager in the agent container.
# Run this first to determine what tools can be installed.

data "external" "agent_env" {
  program = ["sh", "-c", <<-EOT
    os=$(cat /etc/os-release 2>/dev/null | tr '\n' '|' || echo "unknown")
    pkg_apt=$(command -v apt-get 2>/dev/null || echo "")
    pkg_apk=$(command -v apk 2>/dev/null || echo "")
    pkg_yum=$(command -v yum 2>/dev/null || echo "")
    pkg_dnf=$(command -v dnf 2>/dev/null || echo "")
    tools=$(for t in curl nslookup dig nc traceroute openssl awk grep sed; do command -v $t >/dev/null 2>&1 && echo -n "$t "; done)
    echo "{\"os\": $(echo "$os" | sed 's/"/\\"/g' | awk '{print "\"" $0 "\""}'), \"apt_get\": \"$pkg_apt\", \"apk\": \"$pkg_apk\", \"yum\": \"$pkg_yum\", \"dnf\": \"$pkg_dnf\", \"available_tools\": \"$tools\"}"
  EOT
  ]
}

output "agent_environment" {
  description = "OS info and available package managers and tools in the agent container."
  value       = data.external.agent_env.result
}
