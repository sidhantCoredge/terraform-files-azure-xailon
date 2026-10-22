# ──────────────────────────────────────────────────────────────────────────────
# Observability: Azure Monitor workspace (Managed Prometheus) + Managed Grafana
#
# The metrics path:
#   AKS (monitor_metrics addon) ──▶ Data Collection Rule ──▶ Monitor workspace
#                                                                  │ (Managed Identity)
#                                                            Managed Grafana
#
# The AKS `monitor_metrics` block is NOT in this file — it has to be added to
# `aks.tf` (snippet in §4 below). aks.tf was deliberately left untouched.
#
# COST (note: logging was switched off for the same reason — logging.tf.disabled):
#   - Managed Grafana Standard: a per-instance monthly charge. Essential is
#     cheaper but carries no zone redundancy and no SLA.
#   - Monitor workspace: billed on ingested samples. AKS's default Prometheus
#     targets emit a lot of series — review ingestion after the first month.
#   Both are new recurring costs, not one-off ones.
# ──────────────────────────────────────────────────────────────────────────────

# ── 1. Azure Monitor workspace (Managed Prometheus metrics store) ──────────
resource "azurerm_monitor_workspace" "main" {
  name                = "amw-tokenfactory"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location

  # NOTE: setting this to `false` requires an Azure Monitor Private Link Scope
  # (AMPLS). That is a different mechanism from the simple private endpoints used
  # for PostgreSQL/Key Vault/ACR, and it affects all monitoring ingestion at
  # once. Left as `true` for now: the data plane is guarded by Entra plus RBAC,
  # so there is no anonymous read. Going private means building
  # azurerm_monitor_private_link_scope and _scoped_service separately.
  public_network_access_enabled = true

  tags = {
    grafana = "tokenfactory"
  }
}

# ── 2. Managed Grafana ────────────────────────────────────────────────────────
#
# WHY azapi AND NOT azurerm_dashboard_grafana
# The azurerm provider is pinned to "~> 3.0", and on 3.x the
# grafana_major_version argument only accepts "9" or "10":
#
#   Error: expected grafana_major_version to be one of ["9" "10"], got 12
#
# Azure no longer accepts either of those:
#
#   400 GrafanaMajorVersionNotSupported: The requested grafana major version
#   '9' is not valid for sku type Standard. Valid versions: 12, 13
#
# So the typed resource cannot create this at all — the provider's allowed
# values and the API's allowed values no longer overlap. azapi talks to the
# ARM API directly and is already used in this configuration for the same
# reason (see azapi_resource.redis_cluster, where the azurerm schema lagged
# the Redis Enterprise API).
#
# Replace this with azurerm_dashboard_grafana when the provider moves to v4,
# where the argument accepts current versions.
#
# SETTINGS, and why each one:
#   sku Standard          Essential has no SLA and cannot set zoneRedundancy
#   zoneRedundancy Disabled   uaenorth does not offer it — Azure rejects
#                         Enabled outright with ZoneRedundancyNotSupported
#   grafanaMajorVersion 12    the lower of the two still-accepted majors, so it
#                         stays valid longer as Azure retires old ones
#   apiKey Disabled       Entra sign-in only; create service tokens inside
#                         Grafana if ever needed, not here
#   deterministicOutboundIP Enabled   keeps the outbound IPs stable so a later
#                         firewall or NSG allow-list does not break
#   publicNetworkAccess Enabled   the UI resolves publicly but sign-in is Entra
#                         only. Making it private needs a private endpoint and
#                         a private DNS zone — see the note in §5.
resource "azapi_resource" "grafana" {
  type      = "Microsoft.Dashboard/grafana@2023-09-01"
  name      = "amg-tokenfactory"
  location  = var.location
  parent_id = azurerm_resource_group.rg.id

  identity {
    type = "SystemAssigned"
  }

  body = {
    sku = {
      name = "Standard"
    }
    properties = {
      grafanaMajorVersion     = "12"
      zoneRedundancy          = "Disabled"
      apiKey                  = "Disabled"
      deterministicOutboundIP = "Enabled"
      publicNetworkAccess     = "Enabled"
      grafanaIntegrations = {
        azureMonitorWorkspaceIntegrations = [
          {
            azureMonitorWorkspaceResourceId = azurerm_monitor_workspace.main.id
          }
        ]
      }
    }
  }

  # The endpoint and outbound IPs are only known after creation; asking for
  # them here makes them readable from state without a separate data source.
  response_export_values = ["properties.endpoint", "properties.outboundIPs"]

  tags = {
    grafana = "tokenfactory"
  }
}

# ── 3. RBAC — read access for Grafana's managed identity ─────────────────────
# So it can query Prometheus metrics.
resource "azurerm_role_assignment" "grafana_prometheus_reader" {
  scope                = azurerm_monitor_workspace.main.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azapi_resource.grafana.identity[0].principal_id
}

# So platform metrics from the other Azure resources (AKS, PostgreSQL, Event
# Hubs, Key Vault) show up in Grafana. Scoped to this resource group rather than
# the subscription, to keep the grant no wider than it needs to be.
resource "azurerm_role_assignment" "grafana_monitoring_reader" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azapi_resource.grafana.identity[0].principal_id
}

# ── 4. Getting AKS metrics into the workspace ────────────────────────────────
# The Monitor workspace brings its own default DCR/DCE, and AKS has to be
# associated with it. This also needs the following block in `aks.tf`, which has
# NOT been added there — add it when enabling this:
#
#   resource "azurerm_kubernetes_cluster" "aks" {
#     ...
#     monitor_metrics {}          # enables the Managed Prometheus addon
#   }
#
# (An empty block is enough; `annotations_allowed` / `labels_allowed` are only
#  needed to turn pod labels or annotations into metric dimensions.)
resource "azurerm_monitor_data_collection_rule_association" "aks_prometheus" {
  name                    = "dcra-aks-prometheus"
  target_resource_id      = azurerm_kubernetes_cluster.aks.id
  data_collection_rule_id = azurerm_monitor_workspace.main.default_data_collection_rule_id

  description = "Sends the AKS Prometheus metrics to the Monitor workspace"
}

# ── 5. Who may open Grafana ─────────────────────────────────────────────────
# The two assignments in §3 let GRAFANA'S OWN IDENTITY read data. They grant no
# human anything: without the assignment below, opening the Grafana URL returns
# a refusal, which looks like a broken deployment and is not one.
#
# Reuses the same Entra group that administers the cluster, so dashboard access
# and kubectl access are granted and revoked in one place — edit the group, not
# this file.
#
# Grafana Admin is the full role (manage data sources, folders, users). For
# read-only viewers, assign "Grafana Viewer" to a different group instead of
# widening this one.
resource "azurerm_role_assignment" "grafana_admins" {
  scope                = azapi_resource.grafana.id
  role_definition_name = "Grafana Admin"
  principal_id         = var.aks_admin_group_object_id
}

# ── 6. Grafana's own access log ─────────────────────────────────────────────
#
# Separate from the data Grafana DISPLAYS. Metrics live in amw-tokenfactory and
# container logs in law-tokenfactory; this is Grafana's own audit trail — who
# signed in to the dashboard, and when. Without it there is no answer to "who
# opened Grafana last Tuesday", which sits oddly next to the per-person
# attribution now in place on the cluster (Entra RBAC) and on the jumphost
# (Bastion + Entra SSH).
#
# Two of the three available categories are enabled:
#
#   GrafanaLoginEvents       sign-ins. The point of this resource.
#   GrafanaAlertAuthFailure  an alert rule failing to authenticate to its data
#                            source — quiet normally, and worth seeing when not.
#
# GrafanaUsageInsightsEvents is deliberately NOT enabled: it records every
# dashboard view, which is far higher volume and of little security value. The
# workspace is billed per GB ingested, so this is a cost choice as much as a
# signal one.
#
# Volume here is negligible either way — a handful of rows a day, nothing like
# ContainerLogV2.
resource "azurerm_monitor_diagnostic_setting" "grafana" {
  count = var.container_log_export_enabled ? 1 : 0

  name                       = "diag-grafana-to-law"
  target_resource_id         = azapi_resource.grafana.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main[0].id

  enabled_log {
    category = "GrafanaLoginEvents"
  }

  enabled_log {
    category = "GrafanaAlertAuthFailure"
  }

  # Azure returns the resource's metric list on every read, so a resource that
  # emits none would otherwise show a permanent diff. Same treatment as the
  # diagnostic settings in logging_eventhub.tf.
  lifecycle {
    ignore_changes = [metric]
  }
}

# ── outputs ──────────────────────────────────────────────────────────────────
# Commented out deliberately. Outputs print on EVERY apply, and the same was
# done to redis_hostname for that reason. Each value is still retrievable:
#
#   terraform state show azapi_resource.grafana           | grep endpoint
#   terraform state show azurerm_monitor_workspace.main   | grep query_endpoint
#
# Uncomment if something ever needs to consume them programmatically.
#
# output "grafana_endpoint" {
#   value       = azapi_resource.grafana.output.properties.endpoint
#   description = "Grafana URL — sign in with Entra ID"
# }
#
# output "grafana_outbound_ips" {
#   value       = azapi_resource.grafana.output.properties.outboundIPs
#   description = "Stable outbound IPs, for firewall and NSG allow-lists"
# }
#
# output "monitor_workspace_query_endpoint" {
#   value       = azurerm_monitor_workspace.main.query_endpoint
#   description = "Prometheus query endpoint"
# }
