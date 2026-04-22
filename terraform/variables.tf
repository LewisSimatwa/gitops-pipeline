variable "subscription_id" {
  description = "Azure Subscription ID. Find it with: az account show --query id -o tsv"
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Short project identifier used in all resource names. Lowercase, hyphens OK, no spaces."
  type        = string
  default     = "gitops-demo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name must be 3-21 chars, lowercase letters, numbers, hyphens only."
  }
}

variable "environment" {
  description = "Deployment environment label — appended to resource names."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the AKS cluster. Run 'az aks get-versions --location eastus' for available versions."
  type        = string
  default     = "1.29"
}

variable "node_count" {
  description = "Number of worker nodes in the default node pool."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 10
    error_message = "node_count must be between 1 and 10."
  }
}

variable "vm_size" {
  description = "VM SKU for worker nodes. Standard_B2s (2 vCPU, 4 GB) keeps costs low for dev."
  type        = string
  default     = "Standard_B2s"
}

variable "github_org" {
  description = "GitHub organisation name or personal account username."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without the org prefix)."
  type        = string
}

variable "slack_token" {
  description = "Slack bot token for ArgoCD notifications (xoxb-...). Mark sensitive so it never appears in plan output."
  type        = string
  sensitive   = true
  default     = ""   # set via TF_VAR_slack_token env var or terraform.tfvars
}

# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Repository  = "${var.github_org}/${var.github_repo}"
  }
}
