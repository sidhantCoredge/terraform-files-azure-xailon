resource "azurerm_route_table" "rt" {
  name                = "rt-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  route {
    name                   = "route-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.fw.ip_configuration[0].private_ip_address
  }

  tags = {
    rt = "tokenfactory"
  }
}

resource "azurerm_subnet_route_table_association" "aks" {
  subnet_id      = azurerm_subnet.this["snet-aks"].id
  route_table_id = azurerm_route_table.rt.id
}

resource "azurerm_subnet_route_table_association" "mgmt" {
  subnet_id      = azurerm_subnet.this["snet-mgmt"].id
  route_table_id = azurerm_route_table.rt.id
}

resource "azurerm_subnet_route_table_association" "pg" {
  subnet_id      = azurerm_subnet.pg.id
  route_table_id = azurerm_route_table.rt.id
}
