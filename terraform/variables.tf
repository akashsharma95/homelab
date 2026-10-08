variable "tailnet" {
  description = "Tailnet name, e.g. you@example.com or example.com.ts.net"
  type        = string
}

variable "tailnet_acls" {
  description = "Full tailnet ACL rule set. tailscale_acl replaces the entire policy file, so this must reproduce every rule you want to keep. No default: supplying it should be a deliberate act."
  type        = any
}
