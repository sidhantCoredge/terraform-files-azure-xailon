resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "aks-tokenfactory"
  kubernetes_version  = var.kubernetes_version

  # ---- One-way door settings ----
  private_cluster_enabled = true
  sku_tier                = "Standard" # production-grade control plane SLA

  # ---- Default (system) node pool ----
  default_node_pool {
    name                         = "agentpool"
    vm_size                      = "Standard_D4as_v5" # 4 vCPU, 16GB RAM
    node_count                   = 3
    vnet_subnet_id               = azurerm_subnet.this["snet-aks"].id
    only_critical_addons_enabled = true # reserved for system pods only
    os_sku                       = "Ubuntu"
    zones                        = ["1", "2", "3"]

    # Azure fills this block in by itself; leaving it out made every plan show
    # a "- upgrade_settings" drift.
    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 0
      node_soak_duration_in_minutes = 0
    }
  }

  # ---- Identity ----
  identity {
    type = "SystemAssigned"
  }
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # ---- Networking (one-way door) ----
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay" # Azure CNI Overlay
    network_data_plane  = "cilium"  # Cilium dataplane
    network_policy      = "cilium"
    pod_cidr            = "10.244.0.0/16"      # outside the VNet range, immutable
    outbound_type       = "userDefinedRouting" # Route Table already associated with snet-aks
    load_balancer_sku   = "standard"
  }

  # ---- Auth: Entra ID + Azure RBAC for Kubernetes ----
  # Before this the only way in was `az aks get-credentials`, which exports the
  # local account clusterUser_rg-tokenfactory_aks-tokenfactory: a static
  # certificate shared by every operator, with no MFA and no Conditional
  # Access, and no way for kube-audit to say who did anything.
  #
  # local_account_disabled removes clusterUser_/clusterAdmin_ entirely:
  # `az aks get-credentials --admin` stops returning anything, so the static
  # cluster-admin kubeconfig ceases to exist and EVERY path into the cluster is
  # an Entra identity that kube-audit and guard can name.
  #
  # This is a ONE-WAY change in practice. Anything still holding the admin
  # kubeconfig stops working the moment it applies, with no warning. Known
  # consumers at the time of writing: the scripts under ~/xalion on the
  # jumphost, and any hand-run helm upgrade. Argo CD is NOT affected — it runs
  # in-cluster on a ServiceAccount. Terraform is NOT affected — nothing in this
  # configuration reads kube_config or kube_admin_config and there is no
  # kubernetes or helm provider.
  #
  # Break-glass after this: membership of the Entra group in
  # var.aks_admin_group_object_id is the only way in. If that group is emptied
  # or misconfigured, nobody can reach the cluster through kubectl, and the
  # recovery path is to re-add a member in Entra (or, failing that, set this
  # back to false and apply, which is a cluster operation rather than a quick
  # revert).
  local_account_disabled = true

  # `managed = true` is deprecated on azurerm 3.x and removed in v4.0, where it
  # becomes the default. Stated explicitly because this repo pins "~> 3.0";
  # drop the line during the v4 upgrade, not before.
  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
    admin_group_object_ids = [var.aks_admin_group_object_id]
  }

  # ---- Container Insights (AKS container logs to the SOC) ----
  # Installs the ama-logs DaemonSet, which reads /var/log/containers/*.log and
  # ships ContainerLogV2 to the workspace in logging.tf. From there a
  # Data Export rule forwards it to Event Hubs for the partner.
  #
  # This is the ONLY way to collect application stdout/stderr: diagnostic
  # settings carry control-plane logs and physically cannot see what a pod
  # printed. See logging.tf for the cost argument and the hub-count
  # constraint before enabling.
  #
  # dynamic, because the whole feature is gated on one variable — with it
  # false, no agent is installed, no workspace exists and nothing is billed.
  #
  # msi_auth_for_monitoring_enabled = true uses the cluster's managed identity
  # instead of the workspace shared key. Microsoft's recommended setting, and
  # it means no key to rotate or leak.
  dynamic "oms_agent" {
    for_each = var.container_log_export_enabled ? [1] : []
    content {
      log_analytics_workspace_id      = azurerm_log_analytics_workspace.main[0].id
      msi_auth_for_monitoring_enabled = true
    }
  }

  # ---- Managed Prometheus (metrics for Grafana) ----
  # Deploys the ama-metrics pods alongside ama-logs. They scrape the cluster's
  # Prometheus endpoints and ship to the Azure Monitor workspace in grafana.tf,
  # which Managed Grafana reads as its Prometheus data source.
  #
  # An empty block is enough. annotations_allowed / labels_allowed only matter
  # when pod labels or annotations should become metric dimensions, and both
  # increase cardinality — the thing this workspace is billed on.
  #
  # The association that points this cluster at the workspace's default DCR
  # lives in grafana.tf (dcra-aks-prometheus); without that, the addon runs and
  # ships nowhere.
  monitor_metrics {}

  # ---- Security / Integrations ----
  oidc_issuer_enabled          = true
  workload_identity_enabled    = true
  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 168
  azure_policy_enabled         = true

  # ---- Auto-upgrade ----
  #automatic_channel_upgrade = "none"
  #node_os_upgrade_channel   = "NodeImage"


  tags = {
    aks = "tokenfactory"
  }
}

# ---- User node pool (application workloads) ----
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "userpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = "Standard_D8as_v5" # 8 vCPU, 32GB RAM
  node_count            = 3
  vnet_subnet_id        = azurerm_subnet.this["snet-aks"].id
  os_sku                = "Ubuntu"
  zones                 = ["1", "2", "3"]
  mode                  = "User"

  # same drift fix as the system pool above
  upgrade_settings {
    max_surge                     = "10%"
    drain_timeout_in_minutes      = 0
    node_soak_duration_in_minutes = 0
  }

  tags = {
    aks = "tokenfactory"
  }
}

# ---- ACR integration: lets AKS pull images from ACR ----
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

# ---- Ops access through Azure RBAC (Entra group) ----
# Two roles, because they answer different questions: Cluster User Role allows
# `az aks get-credentials` to return a kubeconfig at all and grants nothing
# inside the cluster; RBAC Cluster Admin is what the member may then do.
# Scoped to the cluster, not the resource group, so group membership does not
# imply rights over the firewall, Key Vault or the collectors. Access is
# granted and revoked by editing the Entra group, with no terraform run.
resource "azurerm_role_assignment" "aks_ops_user" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role" # allows get-credentials
  principal_id         = var.aks_admin_group_object_id
}

resource "azurerm_role_assignment" "aks_ops_admin" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = var.aks_admin_group_object_id
}
