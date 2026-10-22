# ============================================================================
# Log Analytics workspace — AKS container logs to the SOC
#
# WHAT THIS FILE IS FOR, AND WHAT IT DELIBERATELY NO LONGER DOES
# This file was previously logging.tf.disabled and defined a workspace plus
# seven diagnostic settings (firewall, Bastion, AKS, Key Vault, activity log,
# PostgreSQL, tfstate blob). Every one of those targets is now covered by
# logging_eventhub.tf, which writes the SAME categories straight to Event Hubs
# with no workspace in the path. Keeping both would ingest the same events
# twice and bill twice, so only the workspace survives here. The removed
# blocks are in git history if a workspace copy is ever wanted:
#
#   git show <commit>:logging.tf.disabled
#
# WHY A WORKSPACE EXISTS AT ALL
# Diagnostic settings carry platform and control-plane logs — what the API
# server did, who authenticated, what changed. They physically cannot carry
# application logs, because there is no API-server event for "a pod wrote a
# line to stdout". Collecting those needs an agent inside the cluster, and
# Microsoft's only supported sink for that agent is a Log Analytics workspace.
# The chain is forced:
#
#   pods -> ama-logs DaemonSet -> workspace -> Data Export -> Event Hub -> SOC
#
# THE COST, STATED PLAINLY
# This is the expensive path, and the reason this file was disabled in the
# first place. Container logs are the highest-volume source in any cluster and
# are billed TWICE on the way to the partner: Log Analytics ingestion per GB,
# then Event Hub throughput. There is no cheaper Microsoft-native route — the
# alternative is an in-cluster shipper (Fluent Bit, Vector, or Cribl Edge,
# which the partner already runs) reading /var/log/containers/*.log and writing
# directly to the hub. That skips the workspace entirely and is the lever to
# pull if the bill becomes a problem.
#
# Everything here is gated on var.container_log_export_enabled. With it false
# nothing is created and nothing is billed.
#
# NOTE: the workspace endpoint is public, for both ingestion and query. The
# rest of the infrastructure sits behind private endpoints, so this is an
# exception. Making it fully private requires an Azure Monitor Private Link
# Scope (AMPLS), which is deliberately out of scope.
#
# NOT INCLUDED, and worth knowing about: the old file also carried an Azure
# Monitor Agent extension and a syslog Data Collection Rule for the jumphost,
# collecting auth/authpriv/local6 — "who logged in and which sudo commands they
# ran". That is low volume and directly complements the Entra work done on the
# cluster, but it is a separate requirement from the partner's container-log
# ask and is not re-enabled here. It is one `git show` away.
# ============================================================================

# Data Export requires the workspace and the destination Event Hub namespace to
# be in the SAME REGION, so this is pinned to var.location alongside
# ehns-tokenfactory rather than placed somewhere cheaper.
#
# retention_in_days is Azure's billable floor at 30. The data is forwarded to
# the partner within minutes, so the workspace is a transit buffer rather than
# an archive — but there is no way to pay for less.
resource "azurerm_log_analytics_workspace" "main" {
  count = var.container_log_export_enabled ? 1 : 0

  name                = "law-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = var.container_log_retention_days

  # Public access is governed by var.monitor_private_only — step 2 of the AMPLS
  # rollout in monitor_private_link.tf. While false these stay Enabled, which
  # is the state the agent was onboarded in; flipping to true routes ingestion
  # and query through the private endpoint only. Authentication is identical
  # either way: Entra plus RBAC. What changes is whether a leaked credential is
  # usable from outside the network.
  internet_ingestion_enabled = !var.monitor_private_only
  internet_query_enabled     = !var.monitor_private_only

  tags = {
    purpose = "aks-container-logs-to-soc"
  }
}

# Basic-plan tables CANNOT be exported — the rule below fails with a validation
# error rather than silently dropping rows. Azure sometimes provisions
# ContainerLogV2 as Basic depending on how the workspace was created, so the
# plan is asserted here instead of assumed.
resource "azurerm_log_analytics_workspace_table" "containerlogv2" {
  count = var.container_log_export_enabled ? 1 : 0

  workspace_id = azurerm_log_analytics_workspace.main[0].id
  name         = "ContainerLogV2"
  plan         = "Analytics"

  # Both retention values are stated EXPLICITLY. Left unset, the provider sends
  # a retention the API rejects as soon as `plan` is specified:
  #
  #   400 InvalidParameter: The specified retention value is invalid
  #
  # On the Analytics plan the interactive retention must be 4-730 days and the
  # total 4-4383. Matching both to the workspace's own retention keeps the
  # table from quietly outliving — or being truncated relative to — the
  # workspace it sits in.
  retention_in_days       = var.container_log_retention_days
  total_retention_in_days = var.container_log_retention_days
}

# ── The export rule ─────────────────────────────────────────────────────────
#
# HUB COUNT — the hard constraint. Data Export to a NAMESPACE makes Azure
# auto-create one event hub per exported table, named am-<TableName>; here
# am-ContainerLogV2. The provider offers no event_hub_name argument, so this
# cannot be pointed at the existing azure-diagnostics hub — the behaviour is
# unavoidable.
#
# ehns-tokenfactory is Standard tier, which caps at 10 hubs, and 9 already
# exist (7 OpenMeter + azure-diagnostics + azure-activity-log-tokenactory).
# This rule takes the LAST SLOT. After it, no new hub can be created in this
# namespace without moving to Premium or standing up a second namespace, so a
# later request for KubeEvents or KubePodInventory is blocked rather than
# merely costly. Adding to table_names here is NOT a free change.
#
# Export is near-real-time and NOT retroactive: only rows arriving after the
# rule is enabled are forwarded. Nothing already in the workspace is replayed.
#
# The partner consumes am-ContainerLogV2 as a SEPARATE source from
# azure-diagnostics — different hub, different connection string.
resource "azurerm_log_analytics_data_export_rule" "aks_containers" {
  count = var.container_log_export_enabled ? 1 : 0

  name                    = "AKS-Logs-to-SOC"
  resource_group_name     = azurerm_resource_group.rg.name
  workspace_resource_id   = azurerm_log_analytics_workspace.main[0].id
  destination_resource_id = azurerm_eventhub_namespace.ehns.id
  table_names             = ["ContainerLogV2"]
  enabled                 = true

  depends_on = [azurerm_log_analytics_workspace_table.containerlogv2]
}

# ── Data Collection Rule — what the agent actually collects ─────────────────
#
# THIS IS NOT OPTIONAL, despite what the Container Insights documentation
# implies. Enabling the add-on through the PORTAL or `az aks enable-addons`
# makes Azure create a DCR named MSCI-<region>-<cluster> and associate it with
# the cluster as a convenience. Enabling it through terraform's oms_agent block
# does NOT: that block sets the add-on profile and nothing else.
#
# Without a DCR the ama-logs pods start, report 3/3 Running, and the add-on
# reports enabled — while every pod logs:
#
#   config::error::Exception while parsing dcr : No JSON file found in the
#   specified directory. Check if mdsd is running in MSI mode.
#
# and collects nothing at all. Diagnosed 21 Oct 2026, after the agent sat
# healthy-looking for twenty minutes without sending a single row.
#
# WHAT IS COLLECTED, AND WHAT IS DELIBERATELY NOT
# streams is limited to Microsoft-ContainerLogV2 — application stdout/stderr,
# which is the whole of what the partner asked for. The add-on's own default
# profile also collects KubeEvents, KubePodInventory, KubeNodeInventory,
# ContainerInventory, Perf and InsightsMetrics. Those power the Container
# Insights UI in the portal, are billed per GB like everything else, and are
# NOT exported to the partner — so collecting them would mean paying to store
# telemetry nobody in this pipeline reads. Add a stream here if the portal
# views are ever wanted, knowing what each one costs.
resource "azurerm_monitor_data_collection_rule" "container_insights" {
  count = var.container_log_export_enabled ? 1 : 0

  # Name is a literal, NOT interpolated from var.location: that variable holds
  # the display name "UAE North", and a space in a DCR name is rejected with a
  # bare `400 InvalidPayload: Data collection rule is invalid` that names no
  # field. The portal would have created this as MSCI-uaenorth-aks-tokenfactory.
  name                = "MSCI-uaenorth-aks-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  description         = "AKS container logs (ContainerLogV2 only) for the partner SOC feed"

  destinations {
    log_analytics {
      name                  = "ciworkspace"
      workspace_resource_id = azurerm_log_analytics_workspace.main[0].id
    }
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = ["Microsoft-ContainerLogV2"]

      # namespaceFilteringMode "Off" means no namespace filter — every
      # namespace is collected. Switching it to "Exclude" with a namespaces
      # list is the cheapest volume lever if the bill needs cutting: kube-system
      # alone is usually a large share and is rarely of interest to a SOC.
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Off"
          namespaces             = []
          enableContainerLogV2   = true
        }
      })
    }
  }

  data_flow {
    streams      = ["Microsoft-ContainerLogV2"]
    destinations = ["ciworkspace"]
  }

  tags = {
    purpose = "aks-container-logs-to-soc"
  }
}

# The association is what actually points the cluster at the rule above. A DCR
# with no association is inert — the agent has no way to discover it, and the
# "No JSON file found" error persists exactly as if the DCR did not exist.
resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  count = var.container_log_export_enabled ? 1 : 0

  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.aks.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights[0].id
  description             = "Associates aks-tokenfactory with the container-log DCR"
}

# ── The partner's consumer group ────────────────────────────────────────────
#
# A consumer group is an independent read position on the hub — its own offset,
# its own bookmark. Consumers that share a group also share that bookmark: they
# split the partitions between them and can move each other's position, so one
# reader can skip messages another has not seen. $Default is where every client
# lands when none is specified, which is exactly why it collects accidental
# collisions.
#
# Named soc-collector to match the group on azure-diagnostics
# (logging_eventhub.tf), so the partner configures both Cribl sources
# identically. Group names are scoped to a hub, so reusing the name here does
# not conflict with the other one.
#
# Same literal-string caveat as the authorization rule below: the hub is
# created by Azure, not terraform, so eventhub_name cannot be a reference.
resource "azurerm_eventhub_consumer_group" "soc_container_logs" {
  count = var.container_log_export_enabled ? 1 : 0

  name                = "soc-collector"
  namespace_name      = azurerm_eventhub_namespace.ehns.name
  eventhub_name       = "am-containerlogv2"
  resource_group_name = azurerm_resource_group.rg.name

  depends_on = [azurerm_log_analytics_data_export_rule.aks_containers]
}

# ── The partner's credential for the container-log hub ──────────────────────
#
# Listen-only and scoped to am-containerlogv2 alone, exactly like soc_listen in
# logging_eventhub.tf is scoped to azure-diagnostics. A namespace-level rule
# would also read the OpenMeter billing topics (om_*), which is why neither is
# written that way.
#
# eventhub_name is a STRING LITERAL, not a resource reference, because the hub
# is created by AZURE, not by terraform: a Data Export rule pointed at a
# namespace auto-creates one hub per exported table, named am-<TableName>
# lowercased. Terraform never owns it, so there is nothing to reference.
#
# Consequence on a FRESH install: the export rule must have run and delivered
# at least one batch before this resource can be created, because the hub does
# not exist until then. It took roughly 25 minutes on 21 Oct 2026. If a fresh
# apply fails here with "not found", re-run it once logs are flowing rather
# than assuming the configuration is wrong.
#
# This is a SECOND credential for the partner. Their existing soc-listen
# connection string is scoped to azure-diagnostics and will NOT read this hub —
# it is a separate Cribl source for them, not an extension of the current one.
resource "azurerm_eventhub_authorization_rule" "soc_container_logs" {
  count = var.container_log_export_enabled ? 1 : 0

  name                = "soc-listen-containers"
  namespace_name      = azurerm_eventhub_namespace.ehns.name
  eventhub_name       = "am-containerlogv2"
  resource_group_name = azurerm_resource_group.rg.name

  listen = true
  send   = false
  manage = false

  depends_on = [azurerm_log_analytics_data_export_rule.aks_containers]
}

# ── A note on what the portal does differently ──────────────────────────────
#
# Enabling Container Insights through the portal or `az aks enable-addons`
# creates the DCR above automatically, in the NODE resource group
# (MC_rg-tokenfactory_aks-tokenfactory_uaenorth), outside terraform. This
# configuration creates it in rg-tokenfactory instead, where it is managed and
# visible alongside everything else. If the add-on is ever re-enabled from the
# portal, check for a duplicate MSCI-* rule in the node resource group before
# assuming the one here is the only thing collecting.
