# vault-agent.hcl
vault {
address = "http://vault:8200"
}

auto_auth {
method "approle" {
mount_path = "auth/approle"
config = {
role_id_file_path = "/vault/secrets/role_id"
secret_id_file_path = "/vault/secrets/secret_id"
secret_id_response_wrapping_path = "auth/approle/role/simulator/secret-id"
remove_secret_id_file_after_reading = true
}
}
}

template {
  contents = <<EOF
{{ with secret "rabbitmq/creds/simulator" }}
RABBITMQ_USERNAME={{ .Data.username }}
RABBITMQ_PASSWORD={{ .Data.password }}
{{ end }}
EOF

  destination = "/vault/secrets/rabbit.env"
  perms       = "0600"
}