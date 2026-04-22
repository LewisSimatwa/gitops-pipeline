# ─── AKS ──────────────────────────────────────────────────────────────────────

output "aks_cluster_name" {
  description = "AKS cluster name."
  value       = module.aks.cluster_name
}

output "aks_resource_group" {
  description = "Resource group that contains the AKS cluster."
  value       = azurerm_resource_group.main.name
}

output "aks_get_credentials_command" {
  description = "Run this command to configure kubectl to talk to your cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${module.aks.cluster_name} --overwrite-existing"
}

# ─── ACR ──────────────────────────────────────────────────────────────────────

output "acr_login_server" {
  description = "ACR login server — use this as the image repository prefix."
  value       = azurerm_container_registry.acr.login_server
}

output "acr_name" {
  description = "ACR resource name (used in az acr commands)."
  value       = azurerm_container_registry.acr.name
}

# ─── GitHub Actions OIDC ──────────────────────────────────────────────────────
# Copy these three values into your GitHub repository secrets.

output "github_actions_client_id" {
  description = "Add to GitHub secrets as AZURE_CLIENT_ID"
  value       = azurerm_user_assigned_identity.github_actions.client_id
}

output "github_actions_subscription_id" {
  description = "Add to GitHub secrets as AZURE_SUBSCRIPTION_ID"
  value       = var.subscription_id
  sensitive   = true
}

output "github_actions_tenant_id" {
  description = "Add to GitHub secrets as AZURE_TENANT_ID"
  value       = data.azurerm_client_config.current.tenant_id
}

# ─── ArgoCD ───────────────────────────────────────────────────────────────────

output "argocd_initial_password_command" {
  description = "Retrieve the auto-generated ArgoCD admin password."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "argocd_port_forward_command" {
  description = "Access the ArgoCD UI at http://localhost:8080"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

# ─── Convenience summary ──────────────────────────────────────────────────────

output "next_steps" {
  description = "What to do after terraform apply completes."
  value       = <<-EOT

    ── Step 1 complete ──────────────────────────────────────────────────────────

    1. Configure kubectl:
       ${azurerm_resource_group.main.name} → az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${module.aks.cluster_name}

    2. Verify namespaces:
       kubectl get namespaces

    3. Access ArgoCD UI:
       kubectl port-forward svc/argocd-server -n argocd 8080:443
       Username: admin
       Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

    4. Add these to GitHub Actions secrets:
       AZURE_CLIENT_ID      = ${azurerm_user_assigned_identity.github_actions.client_id}
       AZURE_TENANT_ID      = ${data.azurerm_client_config.current.tenant_id}
       AZURE_SUBSCRIPTION_ID = <sensitive — run: terraform output github_actions_subscription_id>
       ACR_LOGIN_SERVER     = ${azurerm_container_registry.acr.login_server}

    ────────────────────────────────────────────────────────────────────────────
  EOT
}
