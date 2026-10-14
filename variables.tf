variable "location" {
  default = "UAE North"
}


variable "archive_storage_account_name" {
  description = "Globally unique, lowercase+digits only, max 24 chars"
  default     = "sttokenfactoryarch001"
}

variable "resource_group_name" {
  default = "rg-tokenfactory"
}

variable "vnet_name" {
  default = "vnet-tokenfactory"
}

variable "vnet_address_space" {
  default = ["10.40.0.0/16"]
}

variable "p2s_root_cert_data" {
  description = "Base64 public cert data for P2S VPN root certificate"
  type        = string
}

variable "jumphost_ssh_public_key_path" {
  description = "Path to your local SSH public key"
  default     = "~/.ssh/id_rsa_jumphost.pub"
}

variable "subnets" {
  type = map(object({
    address_prefixes = list(string)
  }))
  default = {
    GatewaySubnet       = { address_prefixes = ["10.40.0.0/27"] }
    AzureBastionSubnet  = { address_prefixes = ["10.40.0.64/26"] }
    AzureFirewallSubnet = { address_prefixes = ["10.40.0.128/26"] }
    snet-mgmt           = { address_prefixes = ["10.40.1.0/27"] }
    snet-pe             = { address_prefixes = ["10.40.3.0/24"] }
    snet-aks            = { address_prefixes = ["10.40.8.0/21"] }
  }
}

variable "pg_subnet_prefix" {
  default = ["10.40.2.0/28"]
}

variable "pg_databases" {
  type    = list(string)
  default = ["tokenfactory", "keycloak", "openmeter", "svix", "openfga"]
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version"
  type        = string
  default     = "1.35.7" # check with `az aks get-versions`; override in terraform.tfvars
}
variable "postgres_version" {
  default = "16"
}

variable "pg_admin_username" {
  default = "pgadmintf"
}

variable "pg_sku_name" {
  description = "GP_ prefix = General Purpose tier"
  default     = "GP_Standard_D8ds_v5"
}

variable "pg_storage_mb" {
  default = 131072 # 128 GB
}

variable "pg_backup_retention_days" {
  default = 30
}

variable "pg_geo_redundant_backup_enabled" {
  default = true
}

variable "pg_zone" {
  default = "1"
}

variable "pg_standby_zone" {
  default = "2"
}
variable "azure_platform_dns" {
  description = "Azure ka reserved internal DNS resolver IP — platform-wide constant"
  default     = "168.63.129.16"
}

# ---- DNS Private Resolver ----
# 10.40.4.0/28 is free: the existing subnets are 0.0/27, 0.64/26, 0.128/26,
# 1.0/27, 2.0/28, 3.0/24 and 8.0/21 — nothing uses 4.x.
variable "dnsr_inbound_subnet_prefix" {
  description = "Subnet for DNS Private Resolver inbound endpoint (min /28, delegated, dedicated)"
  type        = list(string)
  default     = ["10.40.4.0/28"]
}

# Static IP for the inbound endpoint. Azure reserves .0, .1, .2, .3 and the last
# address in every subnet, so .4 is the first usable address in a /28.
variable "dnsr_inbound_ip" {
  description = "Static private IP for the resolver inbound endpoint; the VNet dns_servers points at it"
  type        = string
  default     = "10.40.4.4"
}
