# terraform/ — external resources only

**Optional.** This manages the two genuinely declarative things outside the nodes:

| Resource | Why it is here |
|---|---|
| Tailscale ACL `tagOwners` | Required by the Kubernetes operator; a real API resource |
| Neon project / branch / role | The control-plane datastore |

Node configuration lives in `../ansible`.

## Usage

```bash
export TAILSCALE_API_KEY=...
export NEON_API_KEY=...

terraform init
cp terraform.tfvars.example terraform.tfvars   # fill in
terraform plan
```

## Before you apply

`tailscale_acl` manages the **entire** tailnet policy file. Import your existing policy
first or it will be overwritten:

```bash
terraform import tailscale_acl.this acl
terraform plan     # confirm the diff is only the tagOwners addition
```

## What Terraform cannot do here

**The OAuth client for the operator.** Tailscale has no API for *creating* OAuth clients,
only for using them. Create it in the admin console and pass it to Ansible via
`TS_OAUTH_CLIENT_ID` / `TS_OAUTH_CLIENT_SECRET`.
