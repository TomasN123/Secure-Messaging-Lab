terraform {
  required_version = ">= 1.10"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.10.0"
    }

  }

  backend "s3" {
    bucket       = "tomas-terraform-state-2026"
    key          = "messaging/keycloak-config.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "keycloak" {
  client_id = "admin-cli"
  realm     = "master"
  url       = "https://keycloak.cloud-telemetry.click"
}