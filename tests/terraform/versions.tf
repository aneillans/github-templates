terraform {
  required_version = ">= 1.10"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Settings live in backend.hcl; credentials come from AWS_ACCESS_KEY_ID and
  # AWS_SECRET_ACCESS_KEY, exported by the deploy template's env_secrets.
  backend "s3" {}
}
