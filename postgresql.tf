resource "random_password" "pg_admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "azurerm_postgresql_flexible_server_database" "pg_db" {
  for_each  = toset(var.pg_databases)
  name      = each.value
  server_id = azurerm_postgresql_flexible_server.pg.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

resource "azurerm_private_dns_zone" "pg" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "pg" {
  name                  = "pg-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.pg.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_postgresql_flexible_server" "pg" {
  name                = "psql-tokenfactory"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  version             = var.postgres_version

  delegated_subnet_id = azurerm_subnet.pg.id
  private_dns_zone_id = azurerm_private_dns_zone.pg.id

  administrator_login    = var.pg_admin_username
  administrator_password = random_password.pg_admin.result

  sku_name          = var.pg_sku_name
  storage_mb        = var.pg_storage_mb
  auto_grow_enabled = true

  zone                          = var.pg_zone
  public_network_access_enabled = false

  high_availability {
    mode                      = "ZoneRedundant"
    standby_availability_zone = var.pg_standby_zone
  }

  backup_retention_days        = var.pg_backup_retention_days
  geo_redundant_backup_enabled = var.pg_geo_redundant_backup_enabled

  depends_on = [azurerm_private_dns_zone_virtual_network_link.pg]

  tags = {
    pg = "tokenfactory"
  }
}

# This is a DATA-plane call, not a control-plane one. The vault has no public
# access, so whoever runs the apply has to come from inside the VNet. Terraform
# therefore has to run over the point-to-site VPN, and private DNS has to resolve
# over that VPN (dns_resolver.tf — VNet.dns_servers points at 10.40.4.4).
#
# Verify before running:
#   dig kv-tokenfactory.vault.azure.net +short   ->  10.40.3.6, not a public IP
# Without the VPN this fails with ForbiddenByConnection / 403.
resource "azurerm_key_vault_secret" "pg_admin_password" {
  name         = "pg-admin-password"
  value        = random_password.pg_admin.result
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.kv_admin_self]
}
