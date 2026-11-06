terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket       = "tomas-terraform-state-2026"
    key          = "messaging/vault-config.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "vault" {
  address          = "https://vault.cloud-telemetry.click"
  skip_tls_verify  = true # TEMPORARY: remove when ACME is on production
}