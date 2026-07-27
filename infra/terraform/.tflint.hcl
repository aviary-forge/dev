# tflint config for infra/terraform
# See: https://github.com/terraform-linters/tflint/blob/master/docs/user-guide/config.md

config {
  # Only check the terraform directories in this repo.
  # tflint searches up from the current directory for .tflint.hcl,
  # so this file scopes linting to this subtree.
  force = false
}

# Built-in Terraform rules.
# These catch common mistakes and deprecated syntax.
rule "terraform_deprecated_interpolation" { enabled = true }
rule "terraform_deprecated_index" { enabled = true }
rule "terraform_unused_declarations" { enabled = true }
rule "terraform_comment_syntax" { enabled = true }
rule "terraform_documented_variables" { enabled = true }
rule "terraform_typed_variables" { enabled = true }
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}
rule "terraform_required_version" { enabled = true }
rule "terraform_required_providers" { enabled = true }

# Provider-specific rules would go here if we bundled tflint plugins via Nix.
# Without plugins, tflint only runs the built-in terraform rules above.
# To add cloudflare-specific rules, we'd need to bundle:
#   github.com/cloudflare/terraform-provider-cloudflare/tools/tflint-ruleset
# via a Nix derivation.
