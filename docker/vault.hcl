ui = true

storage "raft" {
  path    = "/vault/file"
  node_id = "raft_node_1"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1   
}

disable_mlock = true

api_addr     = "https://vault.cloud-telemetry.click"
cluster_addr = "https://vault:8201"


seal "awskms" {
  region     = "eu-north-1"
  kms_key_id = "alias/lab_alias"
}
