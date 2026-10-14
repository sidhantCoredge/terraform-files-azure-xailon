# ============================================================================
# Azure DNS Private Resolver
#
# Why this exists: P2S VPN clients need private DNS. Without it
# kv-tokenfactory.vault.azure.net resolves to a public IP and returns 403 — the
# privatelink CNAME is in public DNS, but the private address behind it only
# comes from the VNet-linked private zone.
#
# Azure's platform DNS at 168.63.129.16 is NOT reachable over a P2S VPN; it only
# works from inside an Azure VM. So the VNet needs a real resolver whose private
# IP can be handed to VPN clients as their DNS server.
#
# Note: azurerm_virtual_network_gateway's vpn_client_configuration block has no
# dns_servers argument (schema-verified). P2S clients take DNS from the VNet's
# dns_servers setting, which is what network.tf sets.
# ============================================================================

# The resolver needs its own subnet: it requires a delegation and no other
# resource may live in it. Minimum size /28.
resource "azurerm_subnet" "dnsr_inbound" {
  name                 = "snet-dnsr-inbound"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.dnsr_inbound_subnet_prefix

  delegation {
    name = "dnsr-delegation"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_resolver" "this" {
  name                = "dnsr-tokenfactory"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  virtual_network_id  = azurerm_virtual_network.vnet.id

  tags = {
    dnsr = "tokenfactory"
  }
}

# The inbound endpoint is the private IP a VPN client sends DNS queries to.
# The IP is STATIC on purpose: a dynamic one would force
# azurerm_virtual_network.dns_servers to reference this resource's output, which
# creates a vnet -> subnet -> resolver -> inbound -> vnet cycle. A static IP
# breaks that cycle, because both sides read the same value from a variable.
resource "azurerm_private_dns_resolver_inbound_endpoint" "this" {
  name                    = "dnsr-inbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.this.id
  location                = var.location

  ip_configurations {
    subnet_id                    = azurerm_subnet.dnsr_inbound.id
    private_ip_allocation_method = "Static"
    private_ip_address           = var.dnsr_inbound_ip
  }

  tags = {
    dnsr = "tokenfactory"
  }
}
