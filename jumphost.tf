resource "azurerm_network_interface" "jumphost" {
  name                = "nic-jumphost-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this["snet-mgmt"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_security_group" "jumphost" {
  name                = "nsg-jumphost-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-SSH-From-Bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.40.0.64/26" # AzureBastionSubnet range
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "jumphost" {
  network_interface_id      = azurerm_network_interface.jumphost.id
  network_security_group_id = azurerm_network_security_group.jumphost.id
}

resource "azurerm_linux_virtual_machine" "jumphost" {
  name                = "vm-jumphost-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = "Standard_D2as_v5"
  admin_username      = "azureuser"

  # Azure turned this on by itself, and the provider defaults it to false, so
  # every plan showed a true -> false drift. Setting it explicitly keeps the
  # plan clean.
  vm_agent_platform_updates_enabled = true

  network_interface_ids = [
    azurerm_network_interface.jumphost.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file(var.jumphost_ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # The AADSSHLoginForLinux extension REQUIRES a system-assigned managed
  # identity; without one its install fails with exit code 22 (which is what
  # happened here).
  #
  # This does not contradict the "no ambient credentials on the VM" decision:
  # this identity is DELIBERATELY given no role assignment at all. A managed
  # identity with no roles cannot open any Azure resource — the extension uses
  # it only as a device identity.
  #
  # NEVER GRANT THIS IDENTITY A ROLE.
  identity {
    type = "SystemAssigned"
  }

  tags = {
    vm = "tokenfactory"
  }
}

# ============================================================================
# Entra ID login (SSH key access keeps working alongside it)
#
# The extension does NOT remove local accounts: azureuser plus its SSH key still
# works as the break-glass route, while the team signs in through Entra.
#
# Every Entra user gets their own Linux account named after their UPN, with its
# own home directory, its own ~/.azure token cache, and their real name in
# auth.log. That is what ends the shared-`azureuser` problem.
#
# Who may sign in is DELIBERATELY not defined here. Each person arrives with
# their own Entra identity and gets exactly the access their own Azure RBAC
# grants. Those assignments are managed outside this repository.
#
# Worth knowing: sudo on the VM comes from "Virtual Machine Administrator
# Login", and non-sudo access from "Virtual Machine User Login".
# Owner/Contributor do NOT grant VM sign-in — those roles carry no sign-in
# dataActions at all.
# ============================================================================

resource "azurerm_virtual_machine_extension" "aad_ssh_login" {
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.jumphost.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}
