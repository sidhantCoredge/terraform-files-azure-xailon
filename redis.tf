# ─────────────────────────────────────────────────────────────────────────
# Azure Managed Redis via the azapi provider (NOT azurerm_managed_redis).
#
# WHY azapi: azurerm_managed_redis only exists in azurerm provider v4.x.
# This config pins azurerm ~> 3.0 across 82 live resources — upgrading to
# v4 just for Redis was ruled out (breaking changes, unrelated blast radius).
# azapi talks to the same ARM REST API directly, so it works against any
# azurerm provider version. When azurerm v4 is adopted for real (planned
# separately), these two azapi_resource blocks can be swapped for a native
# azurerm_managed_redis resource — same underlying Azure resource, same
# resource IDs, no data migration needed.
#
# WHY azapi ~> 2.0 (NOT ~> 1.0): azapi carries an embedded copy of the ARM
# schemas and validates `type` against it locally, before any API call.
# v1.15.0 is the final 1.x release and its schema stops at
# Microsoft.Cache/redisEnterprise@2024-06-01-preview, so a `~> 1.0` pin
# rejects the 2025-04-01 GA version at plan time even though ARM itself
# supports it (az provider show Microsoft.Cache lists up to 2026-09-01).
# Dropping to a 2024 API version to satisfy the old schema was rejected:
# the Balanced_* SKU families postdate those versions. azapi 2.x is a
# separate provider from azurerm, so this pin has zero blast radius on the
# 82 live azurerm resources.
#
# 2.x SYNTAX: `body` takes an HCL object directly — no jsonencode() wrapper,
# and `output` is a real object, so no jsondecode() on the way out either.
#
# CONFIDENCE NOTE: every field below is confirmed against the official
# Microsoft.Cache/redisEnterprise + /databases schema reference, AND
# verified to pass azapi 2.13.0's own schema validation at the 2025-04-01
# GA API version with schema_validation_enabled left on — minimumTlsVersion,
# highAvailability, sku.name, clientProtocol, port, clusteringPolicy,
# evictionPolicy, accessKeysAuthentication, and
# persistence.{aofEnabled,rdbEnabled}.
#
# SCHEMA VALIDATION IS NOT ARM VALIDATION. azapi's embedded schema accepted a
# `zones` list here, and ARM then rejected the PUT with a 400: the new
# Balanced_* SKUs apply zone redundancy implicitly and refuse an explicit
# zones block (see the comment on the sku below). Treat a clean plan as
# "well-formed", not "accepted" — SKU availability and per-SKU rules like this
# one only surface on apply.
# ─────────────────────────────────────────────────────────────────────────

locals {
  # TWO VERSIONS, deliberately. Do not collapse them into one.
  #
  # The CLUSTER stays on 2025-04-01 because it was created at that version.
  # Moving it to 2025-07-01 makes azapi require `properties.publicNetworkAccess`,
  # and that property CANNOT BE SET on a cluster created under an older version:
  # a live GET returns null, and the documentation states "null is returned only
  # for clusters created using an old API version which do not have this property
  # and cannot be set."
  # The cluster loses nothing by staying on 2025-04-01 — sku, highAvailability
  # and minimumTlsVersion all exist there.
  redis_api_version = "2025-04-01"

  # DATABASE on 2025-07-01: clusteringPolicy = "NoCluster" is not in the
  # 2025-04-01 enum at all (that version has only EnterpriseCluster | OSSCluster). ARM
  # rejected the PUT outright:
  #   RESPONSE 400 BadRequest: "NoCluster clustering policy is not supported in
  #   API version 2025-04-01. Please set the 'api-version' parameter to a newer
  #   version."
  # azapi 2.13.0's embedded schema accepted NoCluster at 2025-04-01 with
  # validation ON — the schema was wrong
  # and ARM was right. 2025-07-01 is GA, not preview, and was verified against
  # its reference: clusteringPolicy allows EnterpriseCluster | NoCluster |
  # OSSCluster, and evictionPolicy includes NoEviction.
  redis_db_api_version = "2025-07-01" # GA, not preview. Confirmed present in Microsoft.Cache's apiVersions list and accepted by azapi 2.13.0's schema.
}

resource "azapi_resource" "redis_cluster" {
  type      = "Microsoft.Cache/redisEnterprise@${local.redis_api_version}"
  name      = "redis-tokenfactory"
  location  = var.location
  parent_id = azurerm_resource_group.rg.id

  body = {
    # SIZING: Azure reserves ~20% of a SKU's memory for non-cache operations,
    # so usable data memory is ~80% of the headline figure. B10 is 12GB total
    # => ~9.6GB usable.
    #
    # An earlier revision used B20 to clear a "10GiB requirement". THAT NUMBER
    # WAS A MISREAD: the 10Gi came from the bundled subchart's
    # `persistence.size`, which is the PVC DISK size, not a memory cap. The real
    # memory cap is the chart's `maxmemory: 3gb`, and observed usage was
    # ~1.64 MB. B10 is already 3x the cap.
    #
    # THIS IS NOT A ONE-SHOT CHOICE. An earlier revision of this comment said
    # Azure does not support scaling down — that came from the architecture
    # doc ("Scaling down isn't currently supported on Azure Managed Redis"),
    # which CONTRADICTS Microsoft's own how-to-scale page. The authority is the
    # ARM API, asked about this specific cluster:
    #
    #   SUB=$(az account show --query id -o tsv)
    #   az rest --method post --url \
    #     "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-tokenfactory/providers/Microsoft.Cache/redisEnterprise/redis-tokenfactory/listSkusForScaling?api-version=2025-07-01"
    #
    # It returns 37 options for this cluster, in BOTH directions:
    #   smaller : B0 (0.5GB), B1 (1GB), B3/X3 (3GB), B5/X5 (6GB)
    #   same    : B10, X10, M10 (12GB — tier swap, different vCPU ratio)
    #   larger  : B20/X20/M20 (24GB) ... up to 1920GB
    # 12 of the 37 are <= 25GB, i.e. they keep NoCluster available.
    #
    # Scaling rules that DO apply:
    #   - NoCluster (see the database below) only exists at <= 25GB. Going
    #     past that means changing the clustering policy, which brings
    #     CROSSSLOT back and needs the app-side hash-tag change first.
    #   - Scaling DOWN requires current memory usage < the new size. Usage here
    #     is ~1.64 MB, so every smaller SKU is reachable.
    #   - highAvailability is Enabled, so data is preserved and the cache stays
    #     available during a scale (brief connection blips). ~10 min.
    #   - Hostname and access keys do NOT change. The underlying IP CAN change,
    #     which is fine here because everything references the hostname.
    #
    # RIGHT-SIZING: the real cap is maxmemory 3gb, so the floor is
    # 3 / 0.8 = ~4GB total. Balanced_B5 (6GB => ~4.8GB usable) is the correct
    # size and would cut cost; B3 (3GB => 2.4GB usable) falls BELOW the cap.
    # B10 is kept for now only because it is already running and nothing is
    # under pressure.
    sku = { name = "Balanced_B10" } # 12GB, Balanced tier = 4:1 memory:vCPU

    # NO `zones` BLOCK — do not add one back. An earlier revision set
    # zones = ["1","2","3"] and ARM rejected the PUT outright:
    #
    #   RESPONSE 400 BadRequest: "Specifying zones for SKU 'Balanced_B20' is
    #   not supported. Zone redundancy is enabled by default for this SKU in
    #   regions with zones."
    #
    # So zone redundancy is NOT lost by omitting it — Azure applies it for us,
    # and UAE North does have zones (confirmed via the provider's own
    # zoneMappings: 1, 2, 3). This is the opposite of every other zonal
    # resource in this config (public IPs, the VM, disks), where `zones` is
    # required to get redundancy; the new Azure Managed Redis SKU families
    # make it implicit and reject the explicit form. azapi's schema accepts
    # `zones` here, so only an apply surfaces this.
    properties = {
      minimumTlsVersion = "1.2"

      # Stated explicitly rather than inherited. Microsoft's reliability doc:
      # zone redundancy applies ONLY when high availability is on, and HA
      # deploys a minimum of two nodes. Docs say new instances default to HA
      # on, but this is NOT reversible after create — "you can't turn off zone
      # redundancy on existing instances because you can't reverse high
      # availability" — so the intent is written down. Field lives on the
      # CLUSTER, not the database (verified: azapi rejects
      # properties.highAvailability on .../databases@2025-04-01, accepts it
      # here). ARM's 400 above complained ONLY about `zones`, not about this.
      highAvailability = "Enabled"
    }
  }

  tags = {
    redis = "tokenfactory"
  }

  response_export_values = ["properties.hostName"]
}

resource "azapi_resource" "redis_database" {
  type      = "Microsoft.Cache/redisEnterprise/databases@${local.redis_db_api_version}"
  name      = "default"
  parent_id = azapi_resource.redis_cluster.id

  body = {
    properties = {
      clientProtocol = "Plaintext" # app expects non-TLS (chart comment: "app has no TLS")
      port           = 10000       # AMR's standalone endpoint port — NOT 6379
      # NoCluster, NOT EnterpriseCluster. EnterpriseCluster gives a single
      # ENDPOINT but does NOT collapse the key space into one hash slot — it is
      # still sharded. On 11 Oct 2026 that killed tf-ledger in production:
      #   CROSSSLOT Keys in request don't hash to the same slot
      #     command='evalsha' first-key='tf:credit:granted:<org>' slot 9617
      #                       violating-key='tf:credit:used:<org>' slot 14876
      # Enterprise policy permits only DEL, MSET, MGET, EXISTS, UNLINK and TOUCH
      # across slots — EVALSHA is not on that list, and tf-ledger's credit
      # scripts touch granted+used in one script with no hash tag in the keys.
      #
      # NoCluster stores data on each node without sharding, so no slots exist
      # and multi-key scripts work with the keys UNCHANGED — no app change.
      # Constraints: <= 25GB only; policy is fixed at CREATE (NoCluster can move
      # to clustered later, not the reverse); scaling up requires changing the
      # policy first, which brings CROSSSLOT back; and it is less performant
      # because Redis Enterprise only multithreads when the cache is sharded.
      #
      # PLANNED MIGRATION (decided 12 Oct 2026): move to EnterpriseCluster once
      # the app-side hash-tag change lands. The ORDER IS NOT NEGOTIABLE:
      #   1. ship hash tags in tf-ledger + tf-warden together, with the data
      #      migration for tf:credit:used:<org> (see seed.go:54 — money bug)
      #   2. verify in production on this NoCluster instance
      #   3. ONLY THEN flip clusteringPolicy to EnterpriseCluster
      # Flipping first reproduces the 11 Oct outage immediately.
      #
      # The flip itself is allowed in place, and only in this direction:
      # "This property can be updated only if the current value is NoCluster.
      #  If the value is OSSCluster or EnterpriseCluster, it cannot be updated
      #  without deleting the database." Choosing NoCluster kept that door open.
      # On the flip, check `terraform plan` says "update in-place" — if it says
      # "destroy and then create replacement", STOP, the database would be
      # deleted. Whether a policy change preserves data is NOT documented by
      # Microsoft either way; it does not matter here because Redis is a
      # projection and the startup wallet sweep rebuilds it from Postgres
      # (proven live 11 Oct: repairs 4, orgs_compared 4).
      #
      # The permanent fix is hash tags in the app (tf:credit:{<org>}:granted),
      # which the codebase ALREADY uses for tf:{o:%s}:authz:%d in tf-warden.
      # That is a separate, non-urgent change — see
      # dev_docs/2026-10-12/azure-managed-redis-nocluster-resolution.md
      # (the 2026-10-11 doc is SUPERSEDED: it concluded an app change was
      # mandatory, which NoCluster disproved).
      #
      # API VERSION: this resource MUST be on 2025-07-01 (local.redis_db_api_version).
      # NoCluster does not exist in 2025-04-01's enum and ARM returns 400.
      clusteringPolicy = "NoCluster"
      # NoEviction, matching the bundled subchart's deliberate
      # --maxmemory-policy noeviction. The credit-wallet projection's
      # granted/used/seeded counters carry NO TTL and must not be evicted;
      # VolatileLRU evicts TTL'd keys first, which here means the reservation
      # holds (tf:{token,credit,projcap}:resv:*) — a silently dropped hold
      # reopens the in-flight overspend window. NoEviction fails writes loudly
      # instead, and tf-ledger / tf-warden already have fail-closed paths for
      # Redis errors. With a 3gb cap on a 12GB SKU this should never trigger.
      evictionPolicy           = "NoEviction"
      accessKeysAuthentication = "Enabled" # app reads password via secretKeyRef, not Entra ID
      persistence = {
        aofEnabled = false
        rdbEnabled = false
      }
    }
  }
}

# Access keys — app's secretKeyRef needs the actual password value, not just
# the hostname.
#
# sensitive_response_export_values (NOT response_export_values): azapi 2.x
# added a sensitive variant that lands the values in `sensitive_output` and
# marks them sensitive, so they are redacted in plan/apply output and in
# `terraform output`. With the plain variant these cache keys would sit
# unmarked in state and print in cleartext. They are still stored in state
# either way — state lives in the private-endpoint-only blob container.
data "azapi_resource_action" "redis_keys" {
  type        = "Microsoft.Cache/redisEnterprise/databases@${local.redis_db_api_version}"
  resource_id = azapi_resource.redis_database.id
  action      = "listKeys"
  method      = "POST"

  sensitive_response_export_values = ["primaryKey", "secondaryKey"]
}

# ─────────────────────────────────────────────────────────────────────────
# Private networking — ordinary azurerm resources, unaffected by the azapi
# detour above. Same pattern as acr.tf / keyvault.tf.
#
# privatelink.redis.azure.net is the correct zone for Azure Managed Redis.
# privatelink.redisenterprise.cache.azure.net belongs to the OLDER Azure
# Cache for Redis Enterprise tier — same ARM type, same redisEnterprise
# subresource, different product. Confirmed against Microsoft's private
# endpoint DNS zone reference.
# ─────────────────────────────────────────────────────────────────────────

resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.azure.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "redis-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_endpoint" "redis" {
  name                = "pe-redis-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.this["snet-pe"].id

  private_service_connection {
    name                           = "redis-privateserviceconnection"
    private_connection_resource_id = azapi_resource.redis_cluster.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }

  tags = {
    pe = "tokenfactory"
  }
}

# ─────────────────────────────────────────────────────────────────────────
# Access key into Key Vault — the first hop of the chain the app already uses
# for every other credential:
#
#   azapi listKeys -> KV secret -> AKS CSI syncer -> tokenfactory-secrets -> pod
#
# The chart reads Redis auth via secretKeyRef only (never an inline value):
#   global.redis.external.existingSecret = tokenfactory-secrets
#   global.redis.external.passwordKey    = redis-password
# so the secret NAME here must stay "redis-password" to match passwordKey.
#
# KV is RBAC-mode with public_network_access_enabled = false, so this resource
# only applies from inside the VNet (the jumphost) and needs the Key Vault
# Administrator assignment to have landed first — same depends_on as
# azurerm_key_vault_secret.pg_admin_password in postgresql.tf.
#
# Rotation note: this tracks primaryKey. Rotating the cache key in Azure does
# NOT update this secret on its own — a terraform apply re-reads listKeys and
# pushes the new value, after which the syncer propagates it.
# ─────────────────────────────────────────────────────────────────────────

resource "azurerm_key_vault_secret" "redis_password" {
  name         = "redis-password"
  value        = data.azapi_resource_action.redis_keys.sensitive_output.primaryKey
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.kv_admin_self]
}

# Clients connect to this hostname on port 10000 — NOT the privatelink
# hostname, which Microsoft's troubleshooting guide explicitly warns against
# putting in a connection string.


#output "redis_hostname" {
#  value = azapi_resource.redis_cluster.output.properties.hostName
#}
