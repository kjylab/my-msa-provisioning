variable "github_token" {
  description = "GitHub PAT — repo secrets:write 권한 필요. export TF_VAR_github_token=ghp_..."
  type        = string
  sensitive   = true
}

provider "github" {
  token = var.github_token
  owner = "kjylab"
}

# NLB DNS가 바뀔 때마다 terraform apply 하면 자동으로 secret도 갱신됨
resource "github_actions_secret" "e2e_base_url" {
  repository      = "my-msa-user-api-gateway"
  secret_name     = "BASE_URL"
  plaintext_value = "http://${aws_lb.kt-cloud-nlb.dns_name}"
}
