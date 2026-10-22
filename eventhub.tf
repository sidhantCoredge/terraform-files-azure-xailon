resource "azurerm_eventhub_namespace" "ehns" {
  name                = "ehns-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  capacity            = 1

  # Auto-inflate added when the SOC log feed landed on this namespace. Firewall
  # and AKS api-server diagnostics are high volume and share the single
  # throughput unit with metering; without this a log burst would throttle
  # OpenMeter, which carries billing data. Inflating costs money rather than
  # dropping events, which is the right trade for billing data but is a real
  # cost exposure driven by log volume.
  auto_inflate_enabled     = true
  maximum_throughput_units = 5

  # The Kafka protocol is only supported from the Standard tier upwards
  public_network_access_enabled = false

  # `capacity` is the STARTING throughput unit count, not the running one.
  # auto_inflate_enabled hands ownership of it to the service: under load Azure
  # raises it on its own, and on 20 Oct 2026 it was sitting at the ceiling of 5.
  # Terraform reads that back as drift against the 1 above and plans
  # `capacity = 5 -> 1` on every run, which would cut throughput five-fold on
  # the namespace carrying BOTH OpenMeter billing events and the partner SOC
  # feed — the same namespace that logged 4,495 ThrottledRequests at 1 TU.
  #
  # Ignoring it keeps 1 as the floor a fresh install starts from while leaving
  # the live value to auto-inflate. The ceiling is still enforced by
  # maximum_throughput_units, so cost stays bounded.
  lifecycle {
    ignore_changes = [capacity]
  }

  tags = {
    eh = "tokenfactory"
  }
}

locals {
  event_hubs = {
    "om_sys.ingest_events"            = 8
    "om_sys.api_events"               = 4
    "om_sys.balance_worker_events"    = 4
    "om_default_events"               = 1
    "om_sys.balance_worker_dlq"       = 1
    "om_sys.billing_worker_dlq"       = 1
    "om_sys.notification_service_dlq" = 1
  }

  dlq_hubs = toset([
    "om_sys.balance_worker_dlq",
    "om_sys.billing_worker_dlq",
    "om_sys.notification_service_dlq"
  ])
}

resource "azurerm_eventhub" "this" {
  # The capture-enabled hubs can only be created once BOTH role assignments are
  # live; otherwise Azure's linked-access check returns a 400.
  depends_on = [time_sleep.rbac_propagation]

  for_each            = local.event_hubs
  name                = each.key
  namespace_name      = azurerm_eventhub_namespace.ehns.name
  resource_group_name = azurerm_resource_group.rg.name
  partition_count     = each.value
  message_retention   = 7 # the maximum on Standard

  dynamic "capture_description" {
    for_each = contains(local.dlq_hubs, each.key) ? [1] : []
    content {
      enabled             = true
      encoding            = "Avro"
      interval_in_seconds = 300
      size_limit_in_bytes = 314572800
      skip_empty_archives = true

      destination {
        name                = "EventHubArchive.AzureBlockBlob"
        archive_name_format = "{Namespace}/{EventHub}/{PartitionId}/{Year}/{Month}/{Day}/{Hour}/{Minute}/{Second}"
        blob_container_name = azurerm_storage_container.eh_capture.name
        storage_account_id  = azurerm_storage_account.archive.id
      }
    }
  }
}

resource "azurerm_storage_account" "archive" {
  name                     = var.archive_storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  public_network_access_enabled = true # required for the trusted-service bypass

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = {
    storage = "tokenfactory"
  }
}

resource "azurerm_storage_container" "eh_capture" {
  name                  = "eventhub-capture"
  storage_account_name  = azurerm_storage_account.archive.name
  container_access_type = "private"
}

# ── RBAC for Capture ────────────────────────────────────────────────────────
# When an event hub is wired to a storage account as its capture destination,
# Azure runs a "linked access check": the CALLER — this Terraform principal —
# must hold data-plane blob write on that storage account.
#
# Owner/Contributor do NOT satisfy it. Those are control-plane roles and grant
# no blob permission at all. That check failing is why all three DLQ hubs
# returned 400:
#   "Linked access check failed for capture storage destination ...
#    doesn't have the required data plane write permissions"
#
# Microsoft's own documentation (event-hubs-capture-overview) names Storage Blob
# Data Owner as the fix for this exact error, so that is the role granted here.
#
# A managed identity was DELIBERATELY not used. It is only needed when the
# storage account lives in another subscription ("must reside in the same
# subscription as the event hub when you don't use managed identity"), and here
# it is the same subscription. Adding one would also create a chicken-and-egg
# problem: identity[0].principal_id does not resolve at plan time, because the
# list is still empty in state.
#
# Note: azurerm_storage_container is created with the account KEY
# (shared_access_key is still enabled), while the linked-access check looks at
# RBAC — which is why the container had already been created while the hubs were
# still failing.

resource "azurerm_role_assignment" "tf_blob_owner" {
  scope                = azurerm_storage_account.archive.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Azure RBAC is not applied instantly — it takes from 30 seconds to a few
# minutes. Without this wait the first apply can still hit the same 400 even
# after the role has been created.
resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.tf_blob_owner]
  create_duration = "150s"
}

resource "azurerm_private_dns_zone" "eh" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "eh" {
  name                  = "eh-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.eh.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_endpoint" "eh" {
  name                = "pe-eh-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.this["snet-pe"].id

  private_service_connection {
    name                           = "eh-privateserviceconnection"
    private_connection_resource_id = azurerm_eventhub_namespace.ehns.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "eh-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.eh.id]
  }

  tags = {
    pe = "tokenfactory"
  }
}

resource "azurerm_eventhub_namespace_authorization_rule" "openmeter" {
  name                = "openmeter-app"
  namespace_name      = azurerm_eventhub_namespace.ehns.name
  resource_group_name = azurerm_resource_group.rg.name
  listen              = true
  send                = true
  manage              = false
}
