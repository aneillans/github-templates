# Non-secret backend settings for the S3-compatible store. Committed because the
# deploy template inits with -backend-config=backend.hcl whenever the file exists.
bucket = "github-templates"
key    = "tests/terraform.tfstate"
region = "us-east-1"

endpoints = {
  s3 = "https://storage.neillans.co.uk"
}

use_path_style              = true
use_lockfile                = true
skip_credentials_validation = true
skip_region_validation      = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_s3_checksum            = true
