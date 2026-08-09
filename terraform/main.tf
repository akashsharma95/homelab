# Tailscale tailnet policy and the Neon datastore. Node configuration lives in ../ansible.
#
#   terraform init
#   cp terraform.tfvars.example terraform.tfvars
#   terraform plan

terraform {
  required_version = ">= 1.6"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17"
    }
    neon = {
      source  = "kislerdm/neon"
      version = "~> 0.6"
    }
  }
}

# ---------------------------------------------------------------------------------
# Tailscale
# ---------------------------------------------------------------------------------

provider "tailscale" {
  # Set TAILSCALE_API_KEY, or supply an OAuth client via TAILSCALE_OAUTH_CLIENT_ID /
  # TAILSCALE_OAUTH_CLIENT_SECRET.
  tailnet = var.tailnet
}

# Tag ownership required by the Kubernetes operator.
#
# tag:k8s-operator is owned by admins; tag:k8s is owned by the OPERATOR, which is what
# permits it to tag the proxy devices it creates. Without this the operator cannot
# register anything. See ../docs/decisions.md #7.
#
# WARNING: this resource manages the ENTIRE tailnet policy file. Import your existing
# policy before applying, or you will overwrite it:
#   terraform import tailscale_acl.this acl
resource "tailscale_acl" "this" {
  acl = jsonencode({
    tagOwners = {
      "tag:k8s-operator" = ["autogroup:admin"]
      "tag:k8s"          = ["tag:k8s-operator"]
    }

    acls = [
      {
        action = "accept"
        src    = ["*"]
        dst    = ["*:*"]
      },
    ]
  })
}

# NOTE: the OAuth client the operator needs CANNOT be created here — Tailscale exposes no
# API for creating OAuth clients, only for using them. Create it in the admin console
# (Settings > OAuth clients) with scopes:
#     General > Services : Read+Write
#     Devices > Core     : Read+Write
#     Keys > Auth Keys   : Read+Write
# tagged tag:k8s-operator, then feed it to Ansible via TS_OAUTH_CLIENT_ID/SECRET.

# ---------------------------------------------------------------------------------
# Neon — the control-plane datastore
# ---------------------------------------------------------------------------------

provider "neon" {
  # Set NEON_API_KEY.
}

resource "neon_project" "k3s" {
  name      = var.neon_project_name
  region_id = var.neon_region

  # A k3s control plane writes continuously, so the compute never autosuspends.
  # Keeping the minimum small limits how fast the free-tier compute budget burns.
  # See "Known risks" in ../docs/decisions.md.
  branch {
    name          = "main"
    database_name = "neondb"
    role_name     = "neondb_owner"
  }
}

output "datastore_endpoint_hint" {
  description = <<-EOT
    Build K3S_DATASTORE_ENDPOINT from the Neon connection string, with two edits:
      1. use the DIRECT host, not the -pooler host
      2. drop channel_binding — kine's lib/pq driver rejects it
    Format: postgres://USER:PASS@HOST:5432/neondb?sslmode=require
  EOT
  value       = "postgres://<role>:<password>@${neon_project.k3s.database_host}/neondb?sslmode=require"
  sensitive   = false
}
