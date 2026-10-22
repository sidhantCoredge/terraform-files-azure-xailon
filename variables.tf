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
  description = "Azure’s reserved internal DNS resolver IP — platform-wide constant"
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

# ── Site-to-Site VPN ────────────────────────────────────────────────────────
variable "s2s_remote_primary_ip" {
  type        = string
  default     = "74.162.206.233"
  description = "Public IP of the remote site's primary VPN endpoint"
}

variable "s2s_remote_secondary_ip" {
  type        = string
  default     = "20.233.207.64"
  description = "Public IP of the remote site's secondary VPN endpoint (not yet connected)"
}

variable "s2s_remote_address_space" {
  type        = list(string)
  default     = ["10.23.3.0/26"]
  description = "Address space behind the remote VPN endpoint"
}

# ── Partner collector VMs ───────────────────────────────────────────────────
variable "collector_subnet_prefix" {
  type        = list(string)
  default     = ["10.40.5.0/28"]
  description = "Dedicated subnet for the partner collector VMs (verified free 15 Oct 2026)"
}

variable "collector_vip_address" {
  type        = string
  default     = "10.40.5.4"
  description = "Static frontend address of the collector load balancer; .0-.3 are Azure-reserved"
}

variable "collector_vm_size" {
  type        = string
  default     = "Standard_D8als_v7"
  description = "8 vCPU / 16 GB, unrestricted in UAE North across zones 1-2-3"
}

variable "collector_image_version" {
  type        = string
  default     = "24.04.202510010"
  description = "Ubuntu 24.04 LTS image version, pinned rather than latest for reproducible builds"
}

variable "collector_ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa_jumphost.pub"
  description = "Path to the SSH public key for the collector VMs' azureuser account. Defaults to the same key as the jumphost, which means one key opens both; use a separate key if the collectors should have their own blast radius."
}

variable "collector_probe_port" {
  type        = string
  default     = "22"
  description = "TCP port the load balancer probes to decide a collector is healthy. 22 answers 'the VM is alive'; change it to the collector service port for a real health check."
}

variable "eventhub_private_endpoint_ip" {
  type        = string
  default     = "10.40.3.7/32"
  description = "Private endpoint address of ehns-tokenfactory, the single destination the collector subnet may reach for the SOC log feed"
}

variable "aks_admin_group_object_id" {
  type        = string
  description = "Object ID of the Entra group whose members administer the AKS cluster (aks-tokenfactory-admins). Members receive the Cluster User and RBAC Cluster Admin roles on the cluster, which is how cluster access is granted and revoked — edit the group, not this value."
}

# ── AKS container logs to the SOC (logging.tf) ──────────────────────────────
# Defaults to false on purpose. This feature routes application logs through a
# Log Analytics workspace, which bills per GB ingested on top of Event Hub
# throughput, and its export rule consumes the last free hub slot on the
# Standard-tier namespace. It is opted into per environment, never inherited.
variable "container_log_export_enabled" {
  type        = bool
  default     = false
  description = "Enable Container Insights on AKS and export ContainerLogV2 to Event Hubs for the SOC. Creates a Log Analytics workspace and consumes one event hub slot (am-ContainerLogV2). Billed per GB ingested — see logging.tf."
}

variable "container_log_retention_days" {
  type        = number
  default     = 30
  description = "Retention for the container-log workspace. 30 is Azure's billable floor; the workspace is a transit buffer to Event Hubs rather than an archive, so there is nothing to gain above it."
}

# Step 2 of the AMPLS rollout — see monitor_private_link.tf. Leave false until
# the private endpoint exists and DNS resolves to 10.40.3.x from inside the
# VNet; flipping it early removes the agent's ingestion path with no fallback.
variable "monitor_private_only" {
  type        = bool
  default     = false
  description = "Disable public ingestion and query on the Log Analytics workspace. Requires the AMPLS private endpoint to be in place and resolving first."
}
