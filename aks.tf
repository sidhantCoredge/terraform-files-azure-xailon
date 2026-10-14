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
    pod_cidr            = "10.244.0.0/16"      # VNet range se bahar, immutable
    outbound_type       = "userDefinedRouting" # Route Table already snet-aks se associated
    load_balancer_sku   = "standard"
  }

  # ---- Auth: Local accounts + Kubernetes RBAC (kubeconfig export, no Entra ID login) ----
  # (Azure AD RBAC block deliberately NOT used)

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
