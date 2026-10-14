resource "azurerm_storage_account" "tfstate" {
  name                     = "sttokenfactorytfstate001"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "ZRS"
  account_kind             = "StorageV2"

  public_network_access_enabled = true

  blob_properties {
    versioning_enabled = true
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = {
    purpose = "terraform-remote-state"
  }
}

resource "azurerm_private_endpoint" "tfstate_blob" {
  name                = "pe-blob-tfstate-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.this["snet-pe"].id

  private_service_connection {
    name                           = "tfstate-blob-privateserviceconnection"
    private_connection_resource_id = azurerm_storage_account.tfstate.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "tfstate-blob-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }

  tags = {
    pe = "tokenfactory"
  }
}

resource "time_sleep" "tfstate_pe_dns" {
  depends_on      = [azurerm_private_endpoint.tfstate_blob]
  create_duration = "60s"
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_name  = azurerm_storage_account.tfstate.name
  container_access_type = "private"

  depends_on = [time_sleep.tfstate_pe_dns]
}
