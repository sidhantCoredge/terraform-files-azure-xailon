# ─────────────────────────────────────────────────────────────────────────────
# SOC log feed — Azure diagnostics to Event Hub
#
# The second party's collectors consume Azure platform logs from a single event
# hub. Every diagnostic setting below writes to THAT ONE HUB, not to a hub per
# category: the namespace is Standard tier, which caps at 10 event hubs, and 8
# are already in use by OpenMeter. Leaving the hub name unset would make Azure
# create one hub per category and exhaust the namespace.
#
# WHY THIS NAMESPACE AND NOT A NEW ONE
# It already has a private endpoint the collectors can reach, trusted-service
# access is enabled so Azure Monitor can deliver despite public access being
# disabled, and a second namespace would mean another endpoint, another private
# DNS record and another cost line.
#
# THE RISK THAT COMES WITH THAT CHOICE
# Capacity is 1 throughput unit — roughly 1 MB/s ingress — SHARED with the
# metering path. Firewall and AKS api-server logs are the two highest-volume
# sources in any Azure estate, and a burst could throttle OpenMeter, which
# carries billing data. Auto-inflate is enabled below to absorb that; it raises
# cost automatically rather than dropping events, which is the right trade for
# billing data but must be a conscious one.
#
# `category_group = "allLogs"` is used for every target that exposes log
# categories on the resource itself: for a SOC feed completeness matters more
# than selectivity, and it keeps working when Azure adds a category. Storage
# and Redis are the exception and are handled at the end of this file.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_eventhub" "soc_diagnostics" {
  name                = "azure-diagnostics"
  namespace_name      = azurerm_eventhub_namespace.ehns.name
  resource_group_name = azurerm_resource_group.rg.name
  partition_count     = 8 # parallelism for the consumer; cannot be raised later
  message_retention   = 7 # the maximum on Standard
}

# Azure Monitor authenticates to the namespace with this rule when delivering.
# Send only: a diagnostic setting never reads.
resource "azurerm_eventhub_namespace_authorization_rule" "diagnostics_send" {
  name                = "diagnostics-send"
  namespace_name      = azurerm_eventhub_namespace.ehns.name
  resource_group_name = azurerm_resource_group.rg.name
  listen              = false
  send                = true
  manage              = false
}

# The credential handed to the second party. LISTEN ONLY, and scoped to this
# hub rather than the namespace, so it cannot read the metering hubs or write
# anything anywhere.
resource "azurerm_eventhub_authorization_rule" "soc_listen" {
  name                = "soc-listen"
  namespace_name      = azurerm_eventhub_namespace.ehns.name
  eventhub_name       = azurerm_eventhub.soc_diagnostics.name
  resource_group_name = azurerm_resource_group.rg.name
  listen              = true
  send                = false
  manage              = false
}

# A dedicated consumer group keeps their offsets independent of anything else
# reading the hub.
resource "azurerm_eventhub_consumer_group" "soc" {
  name                = "soc-collector"
  namespace_name      = azurerm_eventhub_namespace.ehns.name
  eventhub_name       = azurerm_eventhub.soc_diagnostics.name
  resource_group_name = azurerm_resource_group.rg.name
}

locals {
  # Every resource the second party asked for that exists in this environment.
  # Azure AI Foundry and Application Insights are NOT deployed here.
  soc_log_targets = {
    aks  = azurerm_kubernetes_cluster.aks.id
    acr  = azurerm_container_registry.acr.id
    vnet = azurerm_virtual_network.vnet.id
    # The VPN gateway matters twice over. It is on the partner's list, and
    # TunnelDiagnosticLog and IKEDiagnosticLog are what would have named the
    # dead child SA on 16 Oct 2026 directly, instead of it being inferred from
    # frozen byte counters over several hours.
    vpn_gateway   = azurerm_virtual_network_gateway.vgw.id
    firewall      = azurerm_firewall.fw.id
    bastion       = azurerm_bastion_host.bastion.id
    key_vault     = azurerm_key_vault.kv.id
    postgres      = azurerm_postgresql_flexible_server.pg.id
    eventhub_ns   = azurerm_eventhub_namespace.ehns.id
    nsg_aks       = azurerm_network_security_group.aks.id
    nsg_pg        = azurerm_network_security_group.pg.id
    nsg_pe        = azurerm_network_security_group.pe.id
    nsg_collector = azurerm_network_security_group.collector.id
    nsg_dnsr      = azurerm_network_security_group.dnsr.id
    pip_firewall  = azurerm_public_ip.fw.id
    pip_bastion   = azurerm_public_ip.bastion.id
    pip_vgw       = azurerm_public_ip.vgw.id
  }
}

resource "azurerm_monitor_diagnostic_setting" "soc" {
  for_each = local.soc_log_targets

  name                           = "diag-${each.key}-to-soc-hub"
  target_resource_id             = each.value
  eventhub_name                  = azurerm_eventhub.soc_diagnostics.name
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.diagnostics_send.id

  enabled_log {
    category_group = "allLogs"
  }

  # Metrics are deliberately NOT sent. They are high-volume, of limited value to
  # a SOC, and would compete with the log stream for throughput units.
  #
  # Azure returns the resource's full category list on every read, so a resource
  # that emits no logs at all would otherwise show a permanent diff.
  lifecycle {
    ignore_changes = [metric]
  }
}

# The subscription activity log — who created, changed or deleted which resource.
# Usually the single most valuable source for a SOC, and it is a subscription
# scope rather than a resource, so it cannot go in the map above.
resource "azurerm_monitor_diagnostic_setting" "soc_activity_log" {
  name                           = "diag-activitylog-to-soc-hub"
  target_resource_id             = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  eventhub_name                  = azurerm_eventhub.soc_diagnostics.name
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.diagnostics_send.id

  enabled_log {
    category = "Administrative"
  }
  enabled_log {
    category = "Security"
  }
  enabled_log {
    category = "ServiceHealth"
  }
  enabled_log {
    category = "Alert"
  }
  enabled_log {
    category = "Policy"
  }
  enabled_log {
    category = "ResourceHealth"
  }
  enabled_log {
    category = "Recommendation"
  }
  enabled_log {
    category = "Autoscale"
  }
}

# ── The collectors need a path to the hub ───────────────────────────────────
# The outbound allow rule lives INLINE in collector.tf, not here as a separate
# azurerm_network_security_rule. nsg-collector declares its rules as inline
# `security_rule` blocks, which makes that list authoritative: a standalone rule
# resource is stripped by the NSG on one apply and recreated by itself on the
# next, flip-flopping forever. The same constraint applies to route tables.

# ─────────────────────────────────────────────────────────────────────────────
# Storage accounts and Azure Managed Redis — logs live on a CHILD resource
#
# Neither exposes a single log category on the resource itself; the account and
# the cluster carry metrics only (Capacity/Transaction, AllMetrics). Azure
# rejects category_group = "allLogs" against them outright:
#
#   CategoryGroup: 'allLogs' is not supported, supported ones are: ''
#
# The logs sit one level down — blobServices/default for storage, the database
# for Redis — so these targets need the child resource id. Categories are named
# explicitly rather than grouped: the API reports no category groups for these
# children, and the lists are short and stable.
#
# Verified against the live resources with
#   az monitor diagnostic-settings categories list --resource <child id>
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_monitor_diagnostic_setting" "soc_storage_blob" {
  for_each = {
    storage_arch   = azurerm_storage_account.archive.id
    storage_tfstat = azurerm_storage_account.tfstate.id
  }

  name                           = "diag-${each.key}-blob-to-soc-hub"
  target_resource_id             = "${each.value}/blobServices/default"
  eventhub_name                  = azurerm_eventhub.soc_diagnostics.name
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.diagnostics_send.id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }

  lifecycle {
    ignore_changes = [metric]
  }
}

resource "azurerm_monitor_diagnostic_setting" "soc_redis_db" {
  name                           = "diag-redis-db-to-soc-hub"
  target_resource_id             = azapi_resource.redis_database.id
  eventhub_name                  = azurerm_eventhub.soc_diagnostics.name
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.diagnostics_send.id

  enabled_log {
    category = "ConnectionEvents"
  }

  lifecycle {
    ignore_changes = [metric]
  }
}
