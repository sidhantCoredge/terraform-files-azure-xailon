# ─────────────────────────────────────────────────────────────────────────────
# Partner collector VMs — the ONLY resources the second party may reach
#
# Two collector VMs plus one virtual IP, in a dedicated subnet, behind an NSG
# that denies in BOTH directions. The partner's CIDR (10.23.3.0/26) reaches
# nothing else in the VNet, and these VMs reach nothing else either — so a
# compromise here cannot pivot to AKS, PostgreSQL or Key Vault.
#
# WHY A LOAD BALANCER AND NOT A FLOATING VIP
# The partner asked for a "VIP". Keepalived/VRRP-style floating addresses do
# NOT work on Azure: the platform does not honour gratuitous or unsolicited
# ARP, so a VIP announced by one VM is never learned. The supported equivalent
# is an internal Standard Load Balancer with a static frontend address and a
# health probe. Same single address from the partner's point of view.
#
# BUILD ORDER — deliberate. The subnet and NSG exist with everything denied
# BEFORE the VMs are created, so there is never a window in which the VMs are
# broadly reachable. The inbound allow rule for the partner is added LAST, once
# they confirm which ports they need.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_subnet" "collector" {
  name                 = "snet-collector"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.collector_subnet_prefix
}

# ── Route table — internet egress forced through the firewall ───────────────
# The collectors reach the internet ONLY through the firewall, and the firewall
# allows only the FQDNs named in firewall.tf's `collector-package-installs`
# collection (priority 113): the Ubuntu apt pockets and cribl.io. Everything
# else is denied there, not here.
#
# This replaces an earlier `next_hop_type = "None"` black hole. That stance was
# the right default while the collectors needed nothing but the partner network,
# each other and the Event Hubs private endpoint — but the collector software
# does now need an upstream (kcat and keepalived from the Ubuntu pockets, plus
# Cribl's own packages), and the black hole's own comment named this as the
# correct way to open it: a firewall route and a named application rule, rather
# than unrestricted egress.
#
# Note what is NOT being restored: Azure's default internet route. Sending
# 0.0.0.0/0 to the firewall keeps egress deny-by-default — an FQDN nobody has
# allowed is still dropped — whereas falling back to the platform route would
# depend on default outbound access, which Azure disables for VMs in a Standard
# load balancer backend pool and is in any case being retired.
#
# nsg-collector needs a matching outbound allow to AzureFirewallSubnet, because
# Deny-To-VNet-Outbound at priority 200 covers the firewall's own address. See
# Allow-Collector-To-Firewall below; without it this route sends packets into a
# rule that drops them.
#
# No route is needed for 10.23.3.0/26 either: Azure installs a system route from
# the Local Network Gateway's address space. A manual duplicate was added in the
# portal on 16 Oct 2026 and is removed by this definition — it only displaced
# the system route with an identical one.
resource "azurerm_route_table" "collector" {
  name                = "rt-collector"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  route {
    name                   = "route-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.fw.ip_configuration[0].private_ip_address
  }

  tags = {
    rt = "collector"
  }
}

resource "azurerm_subnet_route_table_association" "collector" {
  subnet_id      = azurerm_subnet.collector.id
  route_table_id = azurerm_route_table.collector.id
}

# ── NSG — closed in both directions ─────────────────────────────────────────
resource "azurerm_network_security_group" "collector" {
  name                = "nsg-collector-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  # ---- INBOUND ----

  # Operators manage these over Bastion, same as the jumphost.
  security_rule {
    name                       = "Allow-SSH-From-Bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.40.0.64/26" # AzureBastionSubnet
    destination_address_prefix = "*"
  }

  # REQUIRED for the load balancer health probe. Without it the probe fails,
  # every backend is marked down and the VIP answers nothing.
  security_rule {
    name                       = "Allow-LB-Probe"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # The partner reaches THESE TWO VMs, and nothing else in the environment.
  # All ports, because the requirement is access to the hosts rather than to a
  # named service; narrowing to specific ports later is a one-line change here.
  #
  # What makes this safe is the scope, not the port list: this rule exists ONLY
  # on nsg-collector. Every other subnet's NSG denies the partner — see the note
  # on the VirtualNetwork tag below — and the outbound rules stop these VMs
  # reaching anything else.
  security_rule {
    name                       = "Allow-Partner-Inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.23.3.0/26"
    destination_address_prefix = "*"
  }

  # The matching INBOUND half. Traffic from the peer collector arrives with a
  # source inside this subnet, which Deny-VNet-Inbound at 4096 would otherwise
  # drop — an outbound allow on its own is not enough for a two-way session.
  security_rule {
    name                       = "Allow-Collector-To-Collector-In"
    priority                   = 150
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.40.5.0/28"
    destination_address_prefix = "*"
  }

  # Everything else in. Note the VirtualNetwork tag now INCLUDES 10.23.3.0/26,
  # because Azure expands it to cover address spaces declared on a Local Network
  # Gateway — so this denies the partner too, until the rule above is added.
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

  # ---- OUTBOUND ----
  # The half that is usually forgotten. Inbound rules stop the partner reaching
  # in; these stop a compromised collector reaching the rest of the estate.

  security_rule {
    name                       = "Allow-Return-To-Partner"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "10.23.3.0/26"
  }

  # The two collectors must reach each other — clustering, state sync and the
  # heartbeat behind the shared VIP all need it. Scoped to this subnet alone, so
  # it opens collector-to-collector and nothing else. Priority must be ABOVE the
  # 200 deny below, which would otherwise catch it: snet-collector is part of
  # the VirtualNetwork tag like every other subnet.
  security_rule {
    name                       = "Allow-Collector-To-Collector"
    priority                   = 150
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "10.40.5.0/28"
  }

  # The SOC log feed. Consuming from Event Hubs needs ONE exception to the deny
  # below, scoped to the private endpoint address and the three ports the
  # clients use: 5671 AMQP, 9093 Kafka, 443 AMQP over WebSockets. Nothing else
  # at that endpoint is reachable, and the credential handed to the partner is
  # listen-only on a single hub.
  security_rule {
    name                       = "Allow-Collector-To-EventHub"
    priority                   = 160
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "5671", "9093"]
    source_address_prefix      = "*"
    destination_address_prefix = var.eventhub_private_endpoint_ip
  }

  # The firewall is the next hop for 0.0.0.0/0 (see rt-collector above), and its
  # private IP sits in AzureFirewallSubnet — inside the VirtualNetwork tag, so
  # the 200 deny below would drop every packet on its way out. Scoped to the
  # firewall subnet alone: this opens the path to the firewall, not to the VNet.
  # What the collectors may then actually reach is decided by the firewall's
  # application rules, not here.
  security_rule {
    name                       = "Allow-Collector-To-Firewall"
    priority                   = 170
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "10.40.0.128/26" # AzureFirewallSubnet
  }

  # No path to AKS, PostgreSQL, Key Vault, the private endpoints or the jumphost.
  #
  # The ranges are listed EXPLICITLY and must not be replaced by the
  # VirtualNetwork service tag, however much tidier that looks. That tag covers
  # the VNet, peered VNets, on-premises space reachable through a gateway AND
  # "address prefixes used on user-defined routes". rt-collector carries a UDR
  # for 0.0.0.0/0 (to the firewall), so under the tag this rule silently became
  # a deny-all: it outranks the platform's AllowInternetOutBound at 65001, and
  # every packet to the internet was dropped by the NSG before it ever reached
  # the firewall to be matched against an application rule.
  #
  # Diagnosed 20 Oct 2026 with Network Watcher, which named it outright:
  #   az network watcher test-ip-flow ... --remote 91.189.92.22:80
  #   -> {"access": "Deny", "ruleName": "securityRules/Deny-To-VNet-Outbound"}
  # The symptom was a TCP timeout with no SYN-ACK, which looks like a firewall
  # drop and is not one.
  #
  # Internet egress now falls through to AllowInternetOutBound and is routed to
  # the firewall, where the FQDN allowlist decides. Denying by name here keeps
  # the estate closed without the tag's UDR expansion changing what it means.
  security_rule {
    name                   = "Deny-To-VNet-Outbound"
    priority               = 200
    direction              = "Outbound"
    access                 = "Deny"
    protocol               = "*"
    source_port_range      = "*"
    destination_port_range = "*"
    source_address_prefix  = "*"
    destination_address_prefixes = [
      "10.40.0.0/16",  # this VNet — AKS, PG, Key Vault, the private endpoints
      "10.23.3.0/26",  # partner space (Allow-Return-To-Partner at 100 wins)
      "172.16.0.0/24", # second address space on the Local Network Gateway
    ]
  }

  tags = {
    nsg = "collector"
  }
}

resource "azurerm_subnet_network_security_group_association" "collector" {
  subnet_id                 = azurerm_subnet.collector.id
  network_security_group_id = azurerm_network_security_group.collector.id
}

# ── The VIP — internal Standard Load Balancer ───────────────────────────────
resource "azurerm_lb" "collector" {
  name                = "lb-collector"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard" # Basic is retired and is not zone-redundant

  frontend_ip_configuration {
    name                          = "collector-vip"
    subnet_id                     = azurerm_subnet.collector.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.collector_vip_address
    zones                         = ["1", "2", "3"] # zone-redundant frontend
  }

  tags = {
    lb = "collector"
  }
}

resource "azurerm_lb_backend_address_pool" "collector" {
  name            = "collector-pool"
  loadbalancer_id = azurerm_lb.collector.id
}

resource "azurerm_network_interface_backend_address_pool_association" "collector" {
  for_each = azurerm_network_interface.collector

  network_interface_id    = each.value.id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.collector.id
}

# ── Probe and rule — the VIP actually forwards ──────────────────────────────
#
# HA PORTS, not a per-port rule. protocol "All" with frontend_port 0 and
# backend_port 0 load-balances EVERY port and protocol through the one rule.
# This is the right shape here for two reasons: the collector service port is
# not known, and a collector is exactly the NVA-style workload HA Ports exists
# for. It requires an INTERNAL Standard load balancer, which this is.
#
# The probe is TCP 22. It answers "is this VM alive", not "is the collector
# healthy" — sshd responding does not prove the collector process is running.
# That is the honest limitation: change collector_probe_port to the real service
# port once it is known, and the probe becomes a genuine health check.
resource "azurerm_lb_probe" "collector" {
  name                = "collector-probe"
  loadbalancer_id     = azurerm_lb.collector.id
  protocol            = "Tcp"
  port                = var.collector_probe_port
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "collector" {
  name            = "collector-ha-ports"
  loadbalancer_id = azurerm_lb.collector.id

  protocol      = "All"
  frontend_port = 0
  backend_port  = 0

  frontend_ip_configuration_name = "collector-vip"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.collector.id]
  probe_id                       = azurerm_lb_probe.collector.id

  # Both collectors answer on the same address, so a connection must stay with
  # whichever one took it. SourceIP keeps a client pinned for the life of the
  # flow; the default five-tuple would scatter a multi-connection session.
  load_distribution = "SourceIP"

  # Preserves the original destination address to the backend rather than
  # rewriting it to the VM address. Required for HA Ports.
  enable_floating_ip = true
}
#
# resource "azurerm_lb_probe" "collector" {
#   name            = "collector-probe"
#   loadbalancer_id = azurerm_lb.collector.id
#   protocol        = "Tcp"
#   port            = <their port>
# }
#
# resource "azurerm_lb_rule" "collector" {
#   name                           = "collector-rule"
#   loadbalancer_id                = azurerm_lb.collector.id
#   protocol                       = "Tcp"
#   frontend_port                  = <their port>
#   backend_port                   = <their port>
#   frontend_ip_configuration_name = "collector-vip"
#   backend_address_pool_ids       = [azurerm_lb_backend_address_pool.collector.id]
#   probe_id                       = azurerm_lb_probe.collector.id
# }

# ── The two collector VMs ───────────────────────────────────────────────────
# One per availability zone, so the load balancer survives a zone failure.
# No public IP on either: they are reached over the tunnel, over Bastion, or
# not at all.
locals {
  collectors = {
    "collector-01" = { zone = "1", ip = "10.40.5.5" }
    "collector-02" = { zone = "2", ip = "10.40.5.6" }
  }
}

resource "azurerm_network_interface" "collector" {
  for_each = local.collectors

  name                = "nic-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  # STATIC, not Dynamic. The partner configures their collectors against these
  # addresses, so they must not move when a VM is resized or reimaged. Azure
  # reserves .0-.3 and .15 in a /28, and .4 is the load-balancer frontend.
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.collector.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.collectors[each.key].ip
  }

  tags = {
    vm = each.key
  }
}

resource "azurerm_linux_virtual_machine" "collector" {
  for_each = local.collectors

  name                = "vm-${each.key}-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  zone                = local.collectors[each.key].zone

  # 8 vCPU / 16 GB, as specified. AMD. Available unrestricted in UAE North
  # across zones 1-2-3 (verified 15 Oct 2026); Standard_F8als_v7 is the
  # compute-optimised alternative at the same vCPU and memory.
  size = var.collector_vm_size

  admin_username                  = "azureuser"
  disable_password_authentication = true

  # Drift suppression, same as jumphost.tf. Azure turns this on by itself after
  # creation while the provider defaults it to false, so leaving it unset makes
  # every plan show a true -> false change for both VMs forever. Setting it to
  # match reality ends that, and keeps the VM agent auto-updating.
  vm_agent_platform_updates_enabled = true

  admin_ssh_key {
    username   = "azureuser"
    public_key = file(var.collector_ssh_public_key_path)
  }

  network_interface_ids = [azurerm_network_interface.collector[each.key].id]

  os_disk {
    name                 = "osdisk-${each.key}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 100
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = var.collector_image_version
  }

  tags = {
    vm      = each.key
    purpose = "partner-collector"
  }
}

# ── Closing the DNS leak ────────────────────────────────────────────────────
# snet-dnsr-inbound has no NSG, so once the tunnel is up the partner can query
# the DNS Private Resolver inbound endpoint on 53 and enumerate every private
# name in the environment — psql-tokenfactory, kv-tokenfactory, each private
# endpoint. Legitimate for a normal site-to-site link; not wanted for a partner
# who should see two collectors.
#
# This is a SINGLE DENY for the partner CIDR and nothing else. The default
# AllowVnetInBound rule (65000) continues to permit every internal subnet, so
# existing resolution for AKS, the jumphost and the collectors is untouched. An
# allow-list NSG here would have been the more thorough shape and also the one
# most likely to break cluster DNS if a source were missed.
resource "azurerm_network_security_group" "dnsr" {
  name                = "nsg-dnsr-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Deny-From-Partner"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.23.3.0/26"
    destination_address_prefix = "*"
  }

  tags = {
    nsg = "dnsr"
  }
}

resource "azurerm_subnet_network_security_group_association" "dnsr" {
  subnet_id                 = azurerm_subnet.dnsr_inbound.id
  network_security_group_id = azurerm_network_security_group.dnsr.id
}
