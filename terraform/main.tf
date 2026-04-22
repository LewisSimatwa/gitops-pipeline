terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.26"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }

  # Remote state in Azure Blob Storage.
  # Create the storage account manually before running terraform init,
  # or comment this block out to use local state during initial development.
  backend "azurerm" {
    resource_group_name  = "rg-gitops-tfstate"
    storage_account_name = "stgitopstfstate193014"   # must be globally unique — change this
    container_name       = "tfstate"
    key                  = "gitops-pipeline.tfstate"
  }
}

# ─── Provider configuration ───────────────────────────────────────────────────

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
}

# Kubernetes and Helm providers are configured after AKS is created.
# They read the cluster credentials from the AKS module output.
provider "kubernetes" {
  host                   = module.aks.kube_config.host
  client_certificate     = base64decode(module.aks.kube_config.client_certificate)
  client_key             = base64decode(module.aks.kube_config.client_key)
  cluster_ca_certificate = base64decode(module.aks.kube_config.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = module.aks.kube_config.host
    client_certificate     = base64decode(module.aks.kube_config.client_certificate)
    client_key             = base64decode(module.aks.kube_config.client_key)
    cluster_ca_certificate = base64decode(module.aks.kube_config.cluster_ca_certificate)
  }
}

# ─── Data sources ─────────────────────────────────────────────────────────────

data "azurerm_client_config" "current" {}

# ─── Resource Group ───────────────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

# ─── Azure Container Registry ─────────────────────────────────────────────────

resource "azurerm_container_registry" "acr" {
  name                = "acr${replace(var.project_name, "-", "")}${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.common_tags
}

# ─── AKS Cluster (via module) ─────────────────────────────────────────────────

module "aks" {
  source = "./modules/aks"

  cluster_name        = "aks-${var.project_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = var.project_name
  kubernetes_version  = var.kubernetes_version
  node_count          = var.node_count
  vm_size             = var.vm_size
  tags                = local.common_tags
}

# ─── Grant AKS kubelet identity AcrPull on the registry ──────────────────────
# This allows every node in the cluster to pull images from ACR
# without storing credentials anywhere.

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = module.aks.kubelet_identity_object_id
}

# ─── Kubernetes Namespaces ────────────────────────────────────────────────────

resource "kubernetes_namespace" "staging" {
  metadata {
    name = "staging"
    labels = {
      environment                             = "staging"
      "managed-by"                            = "terraform"
      # Kyverno uses this label to scope policies to specific namespaces
      "kyverno.io/policy-enforcement"         = "enforce"
    }
  }
  depends_on = [module.aks]
}

resource "kubernetes_namespace" "production" {
  metadata {
    name = "production"
    labels = {
      environment                             = "production"
      "managed-by"                            = "terraform"
      "kyverno.io/policy-enforcement"         = "enforce"
    }
  }
  depends_on = [module.aks]
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "managed-by" = "terraform"
    }
  }
  depends_on = [module.aks]
}

# ─── ArgoCD — install via Helm ────────────────────────────────────────────────
# Helm installs ArgoCD into the argocd namespace created above.
# The Slack webhook secret is injected as an extra secret so it is never
# stored in Git.

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "6.7.14"     # pin chart version for reproducibility
  namespace        = "argocd"
  create_namespace = false        # namespace already created above
  wait             = true
  timeout          = 600

  values = [
    <<-YAML
    server:
      extraArgs:
        - --insecure               # TLS terminated at load-balancer; remove in prod with real certs
    configs:
      params:
        server.insecure: "true"
    notifications:
      enabled: true
      secret:
        create: false              # we manage the secret below so the token is never in state
    YAML
  ]

  depends_on = [kubernetes_namespace.argocd]
}

# ─── ArgoCD notifications secret (Slack webhook token) ────────────────────────
# Store the token in Terraform variables (use a secrets manager in real prod).

resource "kubernetes_secret" "argocd_notifications" {
  metadata {
    name      = "argocd-notifications-secret"
    namespace = "argocd"
  }

  data = {
    "slack-token" = var.slack_token
  }

  depends_on = [helm_release.argocd]
}

# ─── GitHub Actions — OIDC Federated Identity ─────────────────────────────────
# OIDC means GitHub Actions authenticates to Azure without any stored secrets.
# The workflow requests a short-lived token from GitHub's OIDC provider;
# Azure validates it against the federated credential we configure here.

resource "azurerm_user_assigned_identity" "github_actions" {
  name                = "id-github-actions-${var.project_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.common_tags
}

# Scope the federation to main branch pushes only
resource "azurerm_federated_identity_credential" "github_main" {
  name                = "github-actions-main"
  resource_group_name = azurerm_resource_group.main.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  parent_id           = azurerm_user_assigned_identity.github_actions.id
  subject             = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
}

# Also allow pull-request workflows to push images to ACR (but not to AKS)
resource "azurerm_federated_identity_credential" "github_pr" {
  name                = "github-actions-pr"
  resource_group_name = azurerm_resource_group.main.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  parent_id           = azurerm_user_assigned_identity.github_actions.id
  subject             = "repo:${var.github_org}/${var.github_repo}:pull_request"
}

# CI needs to push images to ACR
resource "azurerm_role_assignment" "github_actions_acr_push" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

# CI needs to fetch AKS credentials to run kubectl / helm lint
resource "azurerm_role_assignment" "github_actions_aks_user" {
  scope                = module.aks.cluster_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}
