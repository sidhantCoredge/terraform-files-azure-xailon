# ─────────────────────────────────────────────────────────────────────────
# NSG: snet-pg — allow 5432 only from AKS (the apps) and mgmt (the jumphost)
# ─────────────────────────────────────────────────────────────────────────
resource "azurerm_network_security_group" "pg" {
  name                = "nsg-pg-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-Postgres-From-AKS"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = "10.40.8.0/21" # snet-aks
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Postgres-From-Mgmt"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = "10.40.1.0/27" # snet-mgmt (jumphost)
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-VNet-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  tags = {
    nsg = "tokenfactory"
  }
}

resource "azurerm_subnet_network_security_group_association" "pg" {
  subnet_id                 = azurerm_subnet.pg.id
  network_security_group_id = azurerm_network_security_group.pg.id
}

# ─────────────────────────────────────────────────────────────────────────
# NSG: snet-pe — private endpoints (Key Vault, ACR, Event Hubs) from AKS and mgmt only
# ─────────────────────────────────────────────────────────────────────────
resource "azurerm_network_security_group" "pe" {
  name                = "nsg-pe-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-From-AKS"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.40.8.0/21" # snet-aks
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-From-Mgmt"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.40.1.0/27" # snet-mgmt
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-VNet-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  tags = {
    nsg = "tokenfactory"
  }
}

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.this["snet-pe"].id
  network_security_group_id = azurerm_network_security_group.pe.id
}

# ─────────────────────────────────────────────────────────────────────────
# NSG: snet-aks — deliberately conservative.
# Allow node-to-node traffic (inside the cluster) and mgmt (for debugging);
# deny the rest of the VNet. AzureLoadBalancer health probes stay allowed by the
# default rule at 65001 — we deny the "VirtualNetwork" source only, not "*".
# ─────────────────────────────────────────────────────────────────────────
resource "azurerm_network_security_group" "aks" {
  name                = "nsg-aks-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                   = "Allow-Node-To-Node"
    priority               = 100
    direction              = "Inbound"
    access                 = "Allow"
    protocol               = "*"
    source_port_range      = "*"
    destination_port_range = "*"
    # Node IPs *and* the pod CIDR. The pod CIDR (10.244.0.0/16) is NOT part of
    # the VNet address space (10.40.0.0/16), so a cross-node pod-to-pod packet
    # matched neither this rule nor the `VirtualNetwork` tag — it fell through to
    # the default DenyAllInBound (65500) and died there.
    #
    # Proved live on 6 Oct, from the syncer pod at 10.244.3.37:
    #   same-node pod          10.244.3.121:8888   OK
    #   other node's HOST IP   10.40.8.7:10250     OK    <- source is a node IP, matches
    #   cross-node POD         10.244.2.86:8181    FAIL  <- source is a pod IP, no match
    # This is also what had killed kube-dns (the CoreDNS pods sit on other nodes),
    # producing DNS timeouts across the whole cluster.
    source_address_prefixes    = ["10.40.8.0/21", "10.244.0.0/16"]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-From-Mgmt"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.40.1.0/27" # snet-mgmt
    destination_address_prefix = "*"
  }

  # For Load Balancer health probes — this rule is REQUIRED.
  #
  # The default AllowAzureLoadBalancerInBound rule sits at priority 65001, but
  # the Deny-VNet-Inbound rule below is at 4096. Probes arrive from
  # 168.63.129.16, the host's virtual IP, and that address falls INSIDE the
  # "VirtualNetwork" service tag — Microsoft's documentation states the tag
  # includes "the virtual IP address of the host".
  #
  # An NSG takes the first match and 4096 < 65001, so without this rule the
  # probes are denied and EVERY LoadBalancer service reports unhealthy. An empty
  # cluster hides this; it only surfaces on the first workload.
  security_rule {
    name                       = "Allow-AzureLoadBalancer"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-VNet-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  tags = {
    nsg = "tokenfactory"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.this["snet-aks"].id
  network_security_group_id = azurerm_network_security_group.aks.id
}
