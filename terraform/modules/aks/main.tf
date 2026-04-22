# ─────────────────────────────────────────────────────────────────────────────
# AKS cluster module.
# Creates the cluster, configures the system node pool, and exposes
# the kubeconfig and identity outputs the root module needs.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.dns_prefix
  kubernetes_version  = var.kubernetes_version

  # ─── Default (system) node pool ─────────────────────────────────────────────
  default_node_pool {
    name    = "system"
    vm_size = var.vm_size

    # Fixed node count — auto-scaling is off to control costs during dev.
    # Flip to enable_auto_scaling = true + min/max_count for production.
    node_count           = var.node_count
    enable_auto_scaling  = false
    os_disk_size_gb      = 30
    type                 = "VirtualMachineScaleSets"

    # Only system pods run on this pool — keeps it stable.
    only_critical_addons_enabled = false

    upgrade_settings {
      max_surge = "10%"
    }
  }

  # ─── Managed identity ────────────────────────────────────────────────────────
  # SystemAssigned means Azure manages the identity lifecycle automatically.
  # The kubelet gets its own separate managed identity (kubelet_identity),
  # which is what we use for AcrPull.
  identity {
    type = "SystemAssigned"
  }

  # ─── Networking ──────────────────────────────────────────────────────────────
  network_profile {
    network_plugin    = "azure"         # Azure CNI — pods get VNet IPs
    load_balancer_sku = "standard"      # required for availability zones
    outbound_type     = "loadBalancer"
  }

  # ─── Add-ons ─────────────────────────────────────────────────────────────────
  # Azure Monitor metrics (free tier) — useful for watching resource usage.
  monitor_metrics {}

  # ─── Security ────────────────────────────────────────────────────────────────
  # Keep local accounts enabled for initial setup (ArgoCD bootstrap uses them).
  # In production you would disable this and use AAD integration.
  local_account_disabled = false

  # RBAC is always on in AKS; this enables Kubernetes RBAC (not AAD RBAC).
  role_based_access_control_enabled = true

  oidc_issuer_enabled = true

  tags = var.tags

  # Ignore changes to kubernetes_version after initial creation.
  # Upgrades should go through a deliberate process, not auto-apply.
  lifecycle {
    ignore_changes = [kubernetes_version]
  }
}

# ─── Variables ────────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the AKS cluster resource."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy the cluster into."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "dns_prefix" {
  description = "DNS prefix for the cluster API server FQDN."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version."
  type        = string
}

variable "node_count" {
  description = "Number of nodes in the default pool."
  type        = number
  default     = 2
}

variable "vm_size" {
  description = "VM SKU for nodes."
  type        = string
  default     = "Standard_B2s"
}

variable "tags" {
  description = "Tags to apply to the cluster resource."
  type        = map(string)
  default     = {}
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "The AKS cluster name."
  value       = azurerm_kubernetes_cluster.main.name
}

output "cluster_id" {
  description = "Full resource ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.main.id
}

output "kube_config" {
  description = "Raw kubeconfig block — consumed by the kubernetes and helm providers in the root module."
  value       = azurerm_kubernetes_cluster.main.kube_config[0]
  sensitive   = true
}

output "kubelet_identity_object_id" {
  description = "Object ID of the kubelet managed identity. Used to grant AcrPull."
  value       = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

output "node_resource_group" {
  description = "The auto-generated resource group that holds AKS node VMs."
  value       = azurerm_kubernetes_cluster.main.node_resource_group
}
