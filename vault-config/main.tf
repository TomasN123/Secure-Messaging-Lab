resource "vault_mount" "kvv2_apps" {
  path        = "apps"
  type        = "kv-v2"
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