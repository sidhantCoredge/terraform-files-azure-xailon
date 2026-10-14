resource "azurerm_virtual_network" "vnet" {
  name          = var.vnet_name
  address_space = var.vnet_address_space

  # This is where P2S VPN clients get their DNS server from. The gateway's
  # vpn_client_configuration block has no dns_servers argument at all
  # (schema-verified), so the VNet's own dns_servers is the only way to make
  # private DNS work over the VPN.
  #
  # This USED to be var.azure_platform_dns (168.63.129.16), and THAT WAS A BUG.
  # That address is only reachable from inside an Azure VM, not over a P2S
  # tunnel. Pushed to a client, every DNS query on the laptop went there and
  # timed out — "the internet dies the moment I connect to the VPN".
  #
  # It now points at the resolver's inbound endpoint (dns_resolver.tf). The
  # static IP comes from a variable rather than the resource's output, because
  # referencing the output would create a
  # vnet -> subnet -> resolver -> inbound -> vnet cycle.
  dns_servers         = [var.dnsr_inbound_ip]
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = {
    vnet = "tokenfactory"
  }
}

resource "azurerm_subnet" "this" {
  for_each             = var.subnets
  name                 = each.key
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = each.value.address_prefixes
}

# PostgreSQL gets its own subnet because it needs a delegation.
resource "azurerm_subnet" "pg" {
  name                 = "snet-pg"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.pg_subnet_prefix

  delegation {
    name = "pg-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}
