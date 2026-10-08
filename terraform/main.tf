# Tailscale tailnet policy. Node configuration lives in ../ansible.
#
#   terraform init
#   cp terraform.tfvars.example terraform.tfvars
#   terraform plan

terraform {
  required_version = ">= 1.6"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29"
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

    acls = var.tailnet_acls
  })
}

# NOTE: the OAuth client the operator needs CANNOT be created here — Tailscale exposes no
# API for creating OAuth clients, only for using them. Create it in the admin console
# (Settings > OAuth clients) with scopes:
#     General > Services : Read+Write
#     Devices > Core     : Read+Write
#     Keys > Auth Keys   : Read+Write
# tagged tag:k8s-operator, then feed it to Ansible via TS_OAUTH_CLIENT_ID/SECRET.
