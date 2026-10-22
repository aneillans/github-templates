# Provider-free resources so plan/apply needs no credentials beyond the state store.

variable "label" {
  description = "Prefix for the generated name"
  type        = string
  default     = "github-templates"
}

resource "random_pet" "this" {
  prefix = var.label
  length = 2
}

resource "terraform_data" "marker" {
  input = random_pet.this.id
}

output "name" {
  value = terraform_data.marker.output
}
