# ============================================================================
# Blob private endpoint for sttokenfactoryarch001
#
# Why: the storage account has network_rules.default_action = "Deny" and no VNet
# rule, so the blob data plane was closed from the jumphost (10.40.1.4) and
# `terraform plan` failed on azurerm_storage_container.eh_capture with a 403
# AuthorizationFailure.
#
# An IP rule does NOT fix this. Azure Storage IP rules only apply to requests
# arriving from the public internet. Traffic from a same-region VNet (both are
# uaenorth) travels over the Azure backbone and never matches an IP rule. A
# private endpoint is the only correct answer.
#
# Event Hubs Capture is unaffected: public_network_access_enabled = true and
# bypass = ["AzureServices"] stay as they are, so Capture keeps writing through
# the trusted-service path.
#
# Note: snet-pe carries nsg-pe, which allows only snet-aks (10.40.8.0/21) and
# snet-mgmt (10.40.1.0/27). The jumphost is in snet-mgmt, so it gets through.
# VPN clients (172.16.0.0/24) do not, meaning blob access stays closed from a
# laptop. That is fine — Terraform now runs on the jumphost.
# ============================================================================

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "blob-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_endpoint" "archive_blob" {
  name                = "pe-blob-archive-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.this["snet-pe"].id

  private_service_connection {
    name                           = "blob-privateserviceconnection"
    private_connection_resource_id = azurerm_storage_account.archive.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }

  tags = {
    pe = "tokenfactory"
  }
}
