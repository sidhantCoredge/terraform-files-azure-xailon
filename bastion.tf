resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    bastion = "tokenfactory"
  }
}

resource "azurerm_bastion_host" "bastion" {
  name                = "bas-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  copy_paste_enabled = true
  tunneling_enabled  = true

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = azurerm_subnet.this["AzureBastionSubnet"].id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = {
    bastion = "tokenfactory"
  }
}
