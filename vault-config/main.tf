resource "vault_mount" "kvv2_apps" {
  path = "apps"
  type = "kv-v2"
  options = {
    version = "2"
  }
}

resource "vault_policy" "kv_read" {
  name = "kv-read"

  policy = <<EOT
path "apps/data/lab/*" {
  capabilities = ["read"]
}

path "apps/metadata/lab/*" {
  capabilities = ["list", "read"]
}
EOT
}

resource "vault_audit" "lab_audit" {
  type = "file"

  options = {
    file_path = "/vault/logs/audit.log"
  }
}

data "terraform_remote_state" "vault_client_secret" {
  backend = "s3"

  config = {
    bucket = "tomas-terraform-state-2026"
    key    = "messaging/keycloak-config.tfstate"
    region = "eu-north-1"
  }
}

resource "vault_jwt_auth_backend" "lab_jwt" {
  path               = "oidc"
  type               = "oidc"
  oidc_discovery_url = "https://keycloak.cloud-telemetry.click/realms/plant"
  oidc_client_id     = "vault"
  oidc_client_secret = data.terraform_remote_state.vault_client_secret.outputs.client_secret
  default_role       = "lab_role"
}



resource "vault_jwt_auth_backend_role" "lab_jwt_role" {
  backend               = vault_jwt_auth_backend.lab_jwt.path
  user_claim            = "preferred_username"
  groups_claim          = "groups"
  role_type             = "oidc"
  oidc_scopes           = ["openid"]
  role_name             = "lab_role"
  token_policies        = []
  allowed_redirect_uris = ["https://vault.cloud-telemetry.click/ui/vault/auth/oidc/oidc/callback"]


}

resource "vault_policy" "plant_admin" {
  name = "plant-admin"

  policy = <<EOT
path "apps/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/policies/acl" {
  capabilities = ["list"]
}

path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/audit" {
  capabilities = ["read"]
}
EOT
}

resource "vault_identity_group" "idp_admins" {
  name     = "idp-admins"
  type     = "external"
  policies = [vault_policy.plant_admin.name, vault_policy.tf_vault.name]
}

resource "vault_identity_group" "idp_readers" {
  name     = "idp-readers"
  type     = "external"
  policies = [vault_policy.kv_read.name]
}

resource "vault_identity_group_alias" "idp_admins_alias" {
  name           = "vault-admins"
  mount_accessor = vault_jwt_auth_backend.lab_jwt.accessor
  canonical_id   = vault_identity_group.idp_admins.id
}

resource "vault_identity_group_alias" "idp_readers_alias" {
  name           = "plant-readers"
  mount_accessor = vault_jwt_auth_backend.lab_jwt.accessor
  canonical_id   = vault_identity_group.idp_readers.id
}


resource "vault_policy" "tf_vault" {
  name = "tf-vault"

  policy = <<EOT
path "auth/token/create" {
  capabilities = ["update"]
}

path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]  
}

path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

path "sys/audit/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

path "auth/oidc/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "identity/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "sys/audit" {
  capabilities = ["read", "sudo"]
}

EOT
}