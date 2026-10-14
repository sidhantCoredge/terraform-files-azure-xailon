resource "azurerm_public_ip" "vgw" {
  name                = "pip-vgw-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    vpngw = "tokenfactory"
  }
}

resource "azurerm_virtual_network_gateway" "vgw" {
  name                = "vgw-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  type     = "Vpn"
  vpn_type = "RouteBased"
  sku      = "VpnGw1AZ"

  active_active = false
  enable_bgp    = false

  ip_configuration {
    name                          = "vgw-ipconfig"
    public_ip_address_id          = azurerm_public_ip.vgw.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.this["GatewaySubnet"].id
  }

  # Point-to-Site VPN configuration
  vpn_client_configuration {
    address_space = ["172.16.0.0/24"]

    root_certificate {
      name             = "tokenfactory-root-cert"
      public_cert_data = var.p2s_root_cert_data
    }
  }

  tags = {
    vpngw = "tokenfactory"
  }
}
