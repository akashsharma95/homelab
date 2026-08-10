variable "tailnet" {
  description = "Tailnet name, e.g. you@example.com or example.com.ts.net"
  type        = string
}

variable "neon_project_name" {
  description = "Neon project name for the k3s control-plane datastore"
  type        = string
  default     = "homelab-k3s"
}

variable "neon_region" {
  description = "Neon region. Keep it close to the node that does the most API writes."
  type        = string
  default     = "aws-eu-west-2"
}

variable "tailnet_acls" {
  description = "Full tailnet ACL rule set. tailscale_acl replaces the entire policy file, so this must reproduce every rule you want to keep. No default: supplying it should be a deliberate act."
  type        = any
}
