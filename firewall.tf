resource "azurerm_public_ip" "fw" {
  name                = "pip-firewall-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    fw = "tokenfactory"
  }
}

resource "azurerm_firewall_policy" "fw_policy" {
  name                = "fwpolicy-tokenfactory"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "Standard"
}

resource "azurerm_firewall" "fw" {
  name                = "fw-tokenfactory"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.fw_policy.id

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.this["AzureFirewallSubnet"].id
    public_ip_address_id = azurerm_public_ip.fw.id
  }

  tags = {
    fw = "tokenfactory"
  }
}

resource "azurerm_firewall_policy_rule_collection_group" "aks_bootstrap" {
  name               = "aks-bootstrap"
  firewall_policy_id = azurerm_firewall_policy.fw_policy.id
  priority           = 100

  application_rule_collection {
    name     = "aks-bootstrap-apps"
    priority = 100
    action   = "Allow"

    rule {
      name = "allow-aks-fqdn-tag"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses      = ["10.40.8.0/21"]
      destination_fqdn_tags = ["AzureKubernetesService"]
    }
  }

  application_rule_collection {
    name     = "jumphost-package-installs"
    priority = 102
    action   = "Allow"

    rule {
      name = "allow-package-installs"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.1.0/27"]
      destination_fqdns = [
        "bootstrap.pypa.io",
        "pypi.org",
        "files.pythonhosted.org",
        "dl.k8s.io",
        "storage.googleapis.com",
        "apt.postgresql.org",
        "www.postgresql.org",
        "get.helm.sh",
        "apt.releases.hashicorp.com",
        "registry.terraform.io",
        "releases.hashicorp.com",
        "packages.microsoft.com",
        "keys.openpgp.org",
        "sttokenfactoryarch001.blob.core.windows.net"
      ]
    }
  }

  application_rule_collection {
    name     = "jumphost-azure-control-plane"
    priority = 103
    action   = "Allow"

    rule {
      name = "allow-entra-arm"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.1.0/27"]
      destination_fqdns = [
        "login.microsoftonline.com",
        "management.azure.com",
        "graph.microsoft.com"
      ]
    }
  }

  application_rule_collection {
    name     = "jumphost-apt-mirror"
    priority = 104
    action   = "Allow"

    rule {
      name = "allow-ubuntu-apt"

      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.1.0/27"]
      destination_fqdns = [
        "azure.archive.ubuntu.com",
        "archive.ubuntu.com",
        "security.ubuntu.com",
        "changelogs.ubuntu.com"
      ]
    }
  }

  # Needed to run the Azure Monitor Agent (AMA) on the jumphost.
  #
  # Without these, AMA never fetches its DCR configuration from the control
  # plane: /etc/opt/microsoft/azuremonitoragent/config-cache/configchunks/ stays
  # empty and mdsd.err reports "Could not obtain configuration". Syslog never
  # reaches the workspace.
  #
  # These FQDNs are not guesses — they came out of the firewall's own deny logs:
  #   AzureDiagnostics | where Category == "AZFWApplicationRule"
  #                       and Action_s == "Deny" | summarize by Fqdn_s
  #
  # The ods.opinsights endpoint is workspace-specific (the workspace ID is the
  # hostname), so it is a wildcard here — changing the workspace will not break
  # the rule.
  application_rule_collection {
    name     = "jumphost-azure-monitor-agent"
    priority = 105
    action   = "Allow"

    rule {
      name = "allow-ama-control-and-ingestion"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.1.0/27"]
      destination_fqdns = [
        "global.handler.control.monitor.azure.com",
        "uaenorth.handler.control.monitor.azure.com",
        "*.ods.opinsights.azure.com",
        "*.oms.opinsights.azure.com",
        "*.monitoring.azure.com",
      ]
    }
  }

  # For pulling container images from the AKS subnet.
  #
  # NOTE: these rules are NOT required when images are brought into ACR with
  # `az acr import` — that import runs inside ACR's own service, never traverses
  # this firewall, and AKS then pulls from ACR over a private endpoint. This
  # collection only matters when AKS pulls directly from a public registry.
  application_rule_collection {
    name     = "aks-container-registries"
    priority = 106
    action   = "Allow"

    rule {
      name = "allow-image-pull"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.8.0/21"]
      destination_fqdns = [
        "ghcr.io",
        "pkg-containers.githubusercontent.com", # ghcr ka blob backend
        "*.githubusercontent.com",
      ]
    }
  }

  # Docker Hub — for the three initContainer images that cannot come from ACR.
  #
  # These three are HARDCODED in the chart templates, so they never go through
  # `common.images.image` and the `global.imageRegistry` ACR prefix never
  # applies to them:
  #
  #   busybox:1.36                   minio's fix-data-ownership init
  #   busybox:1.36@sha256:73aaf09…   tf-auth's wait-for-migrate init
  #   curlimages/curl:8.11.1         tf-ledger's geoip-fetch init
  #
  # The minio and tf-ledger ones can be overridden from values
  # (initContainers.chownImage / geoip.fetchImage), but tf-auth's is fully
  # hardcoded, digest included, with no knob at all. So the path has to be
  # opened.
  #
  # A Docker Hub pull touches three separate hosts:
  #   registry-1.docker.io              registry API (manifest)
  #   auth.docker.io                    anonymous pull token
  #   production.cloudflare.docker.com  layer blobs (CDN)
  # All three are needed. Opening only registry-1 gets the manifest but the
  # layers stall, and the pod sits in "ImagePullBackOff" with no clear reason.
  application_rule_collection {
    name     = "aks-dockerhub-init-images"
    priority = 110
    action   = "Allow"

    rule {
      name = "allow-dockerhub-pull"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.8.0/21"]
      destination_fqdns = [
        "registry-1.docker.io",
        "auth.docker.io",
        "index.docker.io",
        # Docker Hub serves blobs from TWO backends — Cloudflare OR AWS
        # CloudFront, depending on routing. Only the Cloudflare one was open, and
        # uaenorth was routed to CloudFront, so the manifest arrived but the layer
        # download failed with `EOF`:
        #   Get "https://production.cloudfront.docker.com/registry-v2/.../blobs/..." : EOF
        # (seen live on openmeter-redis-master-0, pulling bitnamilegacy/redis).
        "production.cloudflare.docker.com",
        "production.cloudfront.docker.com",
      ]
    }
  }

  # Application runtime egress — third-party APIs, GitHub and Maven Central.
  #
  # github.com is here for TWO separate needs, which is why the source covers
  # BOTH the jumphost and AKS:
  #   1. jumphost (10.40.1.0/27): `git clone` / `git pull`. Previously only
  #      *.githubusercontent.com was open, and only for the AKS subnet, so a
  #      clone from the jumphost timed out silently.
  #   2. AKS (10.40.8.0/21): tf-ledger's geoip database comes from GitHub
  #      RELEASES — https://github.com/sapics/ip-location-db/releases/download/
  #      latest/dbip-city-ipv{4,6}.mmdb. The download hits github.com first and
  #      then redirects to *.githubusercontent.com, so both are needed.
  #      (*.githubusercontent.com already exists for AKS in rule 106; it is
  #      repeated here for the jumphost.)
  #   codeload.github.com — for `git archive` and tarball downloads.
  #
  # repo1.maven.org — Keycloak's providers initContainer pulls the
  # keycloak-2fa-email-authenticator jar from here (PROVIDER_URL_0). This is
  # needed from AKS ONLY. Without it the jar is missing, Keycloak starts without
  # the provider, and tf-auth's bootstrap fails CLOSED and crashloops — the
  # chart's own comment says exactly this (infrastructure/keycloak values).
  application_rule_collection {
    name     = "github-and-maven"
    priority = 111
    action   = "Allow"

    rule {
      name = "allow-github"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.1.0/27", "10.40.8.0/21"]
      destination_fqdns = [
        "github.com",
        "codeload.github.com",
        "*.githubusercontent.com",
        # ghcr.io is needed from the jumphost too: the dependency chart for
        # helm/infrastructure/openmeter comes from
        # oci://ghcr.io/openmeterio/helm-charts, and `helm dependency build`
        # ALWAYS re-downloads it — it does not skip even when charts/ is already
        # populated, and deploy-openmeter.sh runs that command every time.
        # (Rule 106 has ghcr.io, but its source is the AKS subnet only, so it is
        # repeated here for the jumphost.)
        "ghcr.io",
        "pkg-containers.githubusercontent.com",
        "registry-1.docker.io",
        "auth.docker.io",
        "index.docker.io",
        "production.cloudflare.docker.com",
        "production.cloudfront.docker.com",
      ]
    }

    rule {
      name = "allow-maven-central"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.8.0/21"]
      destination_fqdns = [
        "repo1.maven.org",
      ]
    }
  }

  #
  # !! THIS LIST STILL NEEDS CONFIRMING !!
  # The FQDNs below are based on which services production uses (Resend, Stripe,
  # Entra BYOIDC, Google BYOIDC). The real list should be reconciled against the
  # application's own configuration — a missed endpoint is blocked silently and
  # surfaces as a timeout in the app, not as anything in the firewall.
  #
  # How to debug it: read the AZFWApplicationRule deny logs. But note that
  # logging is currently OFF (logging.tf.disabled). Turn it on for the day of a
  # deployment, otherwise blocked traffic is invisible.
  application_rule_collection {
    name     = "aks-app-egress"
    priority = 107
    action   = "Allow"

    rule {
      name = "allow-identity-providers"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.8.0/21"]
      destination_fqdns = [
        # Microsoft Entra (BYOIDC)
        "login.microsoftonline.com",
        "graph.microsoft.com",
        # Google (BYOIDC)
        "accounts.google.com",
        "oauth2.googleapis.com",
        "www.googleapis.com",
        "openidconnect.googleapis.com",
      ]
    }

    rule {
      name = "allow-saas-apis"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.8.0/21"]
      destination_fqdns = [
        "api.stripe.com",   # payments
        "files.stripe.com", # Stripe ke hosted assets
        "api.resend.com",   # transactional email
      ]
    }
  }

  # Cloudflare Tunnel (cloudflared) — outbound only.
  #
  # cloudflared connects to Cloudflare's edge on port 7844, not 443:
  #   - UDP 7844  -> quic  (default)
  #   - TCP 7844  -> http2 (fallback, when UDP is unavailable)
  # So this cannot be an APPLICATION rule — Azure Firewall application rules
  # handle HTTP/HTTPS only. It has to be a network rule.
  #
  # IP ranges rather than FQDNs, because FQDNs in network rules only work when
  # DNS proxy is enabled on the firewall policy, and it is off here. Turning DNS
  # proxy on introduces its own problem: the client and the firewall can resolve
  # different addresses and the rule is then missed.
  #
  # These two /24s are reserved for Cloudflare's tunnel endpoints. Confirmed by
  # resolving them from inside the VNet:
  #   region1.v2.argotunnel.com -> 198.41.192.7 … .227   (all in 198.41.192.0/24)
  #   region2.v2.argotunnel.com -> 198.41.200.13 … .233  (all in 198.41.200.0/24)
  network_rule_collection {
    name     = "aks-cloudflare-tunnel"
    priority = 108
    action   = "Allow"

    rule {
      name                  = "allow-cloudflared-quic"
      protocols             = ["UDP"]
      source_addresses      = ["10.40.8.0/21"]
      destination_addresses = ["198.41.192.0/24", "198.41.200.0/24"]
      destination_ports     = ["7844"]
    }

    rule {
      name                  = "allow-cloudflared-http2"
      protocols             = ["TCP"]
      source_addresses      = ["10.40.8.0/21"]
      destination_addresses = ["198.41.192.0/24", "198.41.200.0/24"]
      destination_ports     = ["7844"]
    }
  }

  # Optional cloudflared features — self-update and Access JWT validation. The
  # tunnel runs without them (Cloudflare's own documentation says so), but the
  # log fills with errors. These are HTTPS on 443, so an application rule works.
  application_rule_collection {
    name     = "aks-cloudflare-api"
    priority = 109
    action   = "Allow"

    rule {
      name = "allow-cloudflare-api"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.8.0/21"]
      destination_fqdns = [
        "api.cloudflare.com",
        "update.argotunnel.com",
      ]
    }
  }

  network_rule_collection {
    name     = "aks-bootstrap-network"
    priority = 101
    action   = "Allow"

    rule {
      name                  = "allow-ntp"
      protocols             = ["UDP"]
      source_addresses      = ["10.40.8.0/21"]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }

    rule {
      name                  = "allow-azurecloud-region"
      protocols             = ["TCP"]
      source_addresses      = ["10.40.8.0/21"]
      destination_addresses = ["AzureCloud.uaenorth"]
      destination_ports     = ["9000", "443"]
    }
  }
}
