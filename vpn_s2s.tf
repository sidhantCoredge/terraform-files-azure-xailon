# ─────────────────────────────────────────────────────────────────────────────
# Site-to-Site VPN — remote site 10.23.3.0/26
#
# Reuses the EXISTING gateway (vgw-tokenfactory). No second gateway and no new
# subnet: S2S and the existing P2S configuration coexist on one RouteBased
# gateway, which is why vpn_type must stay "RouteBased" (vpn_gateway.tf).
#
# The remote side supplied an exact IKE/IPsec policy, so it is set explicitly
# rather than left to Azure's defaults. BOTH ENDS MUST MATCH EXACTLY — a single
# mismatched parameter fails phase 1 or phase 2 with no useful diagnostic.
#
# Address-overlap check performed before writing this (all clear):
#   10.23.3.0/26  vs  10.40.0.0/16   (VNet)            no overlap
#                 vs  172.16.0.0/24  (P2S client pool) no overlap
#                 vs  10.244.0.0/16  (AKS pod CIDR)    no overlap
#                 vs  10.0.0.0/16    (AKS service CIDR — not set in aks.tf, so
#                                     AKS applied its default; CONFIRMED live
#                                     on 15 Oct 2026)   no overlap
# ─────────────────────────────────────────────────────────────────────────────

# The pre-shared key is NEVER committed. It lives in Key Vault, seeded by hand,
# and is read here at plan time. The Terraform principal already holds Key Vault
# Administrator (keyvault.tf), so no extra role assignment is needed.
#
#   az keyvault secret set --vault-name kv-tokenfactory \
#     -n s2s-shared-key --file /path/to/psk
data "azurerm_key_vault_secret" "s2s_shared_key" {
  name         = "s2s-shared-key"
  key_vault_id = azurerm_key_vault.kv.id
}

# The remote site. One Local Network Gateway per remote endpoint; a Local
# Network Gateway carries exactly ONE gateway_address, so the secondary public
# IP needs its own LNG + connection (see the commented pair below).
resource "azurerm_local_network_gateway" "remote_primary" {
  name                = "lng-remote-primary"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  gateway_address = var.s2s_remote_primary_ip
  address_space   = var.s2s_remote_address_space

  tags = {
    vpn = "tokenfactory"
  }
}

resource "azurerm_virtual_network_gateway_connection" "remote_primary" {
  name                = "cn-remote-primary"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.vgw.id
  local_network_gateway_id   = azurerm_local_network_gateway.remote_primary.id

  shared_key = data.azurerm_key_vault_secret.s2s_shared_key.value

  # RouteBased requires IKEv2; IKEv1 only works with a policy-based gateway.
  connection_protocol = "IKEv2"
  connection_mode     = "Default"

  # Disabled, as specified. Must stay false on a RouteBased gateway — enabling
  # it turns the tunnel into policy-based traffic selectors and changes how the
  # remote CIDR is matched.
  use_policy_based_traffic_selectors = false

  dpd_timeout_seconds = 45

  # The gateway has enable_bgp = false (vpn_gateway.tf), so routing to the
  # remote site is static, taken from the LNG's address_space.
  enable_bgp = false

  ipsec_policy {
    # Phase 1 (IKE)
    ike_encryption = "AES256"
    ike_integrity  = "SHA256"
    dh_group       = "DHGroup14"

    # Phase 2 (IPsec)
    ipsec_encryption = "AES256"
    ipsec_integrity  = "SHA256"

    # "None" as specified by the remote side. Note this means NO perfect
    # forward secrecy: a compromise of the IKE keys would expose previously
    # captured traffic. It is set this way because both ends must agree and
    # the remote device was configured without PFS.
    pfs_group = "None"

    sa_lifetime = 86400

    # The remote side reported "IPsec SA lifetime: 0", which their device uses to
    # mean "do not rekey on data volume". Azure has no equivalent: the field is a
    # size in KB with a 1024 minimum, and the ARM schema lists it as REQUIRED
    # whenever a custom IPsec policy is set — so it cannot simply be omitted.
    #
    # Set to Azure's documented default, which is large enough that the
    # time-based rekey at 86400 s will almost always fire first on a tunnel
    # scoped to a single service. This is the ONE parameter where the two ends do
    # not match: their device will not rekey on volume, ours may. The remote
    # administrator has to accept that, or both sides have to agree a different
    # policy. Confirm before the first apply.
    sa_datasize = 102400000
  }

  tags = {
    vpn = "tokenfactory"
  }
}

# ── Secondary endpoint (NOT ENABLED) ─────────────────────────────────────────
# The remote side gave a second public IP (20.233.207.64 — Microsoft address
# space, so the far end is very likely an Azure VPN Gateway in active-active
# mode). A second tunnel for redundancy needs its own LNG and connection, and
# our gateway should move to active_active = true so both ends have two
# instances. That is a change to the EXISTING gateway resource and will
# re-create its ip_configuration, so it is deliberately a separate, planned
# change rather than part of this one.
#
# resource "azurerm_local_network_gateway" "remote_secondary" {
#   name                = "lng-remote-secondary"
#   location            = var.location
#   resource_group_name = azurerm_resource_group.rg.name
#   gateway_address     = var.s2s_remote_secondary_ip
#   address_space       = var.s2s_remote_address_space
# }
#
# resource "azurerm_virtual_network_gateway_connection" "remote_secondary" {
#   ... same body, local_network_gateway_id -> remote_secondary ...
# }

# ── Routing — deliberately NOT managed here ─────────────────────────────────
# No route resource for the remote CIDR, for two reasons.
#
# 1. It is unnecessary. Azure installs a system route for the Local Network
#    Gateway's address space, and route selection is longest-prefix-match across
#    all sources — so 10.23.3.0/26 beats rt-tokenfactory's 0.0.0.0/0 UDR to the
#    firewall without any help.
#
# 2. It CONFLICTS. route_table.tf declares its routes as inline `route` blocks,
#    which makes that list authoritative. A separate azurerm_route resource is
#    therefore removed by the route table on one apply and re-created by itself
#    on the next, flip-flopping forever. Inline blocks and azurerm_route
#    resources cannot both manage the same table.
#
# If a route ever is needed here, add it as an inline block in route_table.tf.
