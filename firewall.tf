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
  # Sources: the jumphost AND snet-aks. AKS was added on 21 Oct 2026 when
  # Container Insights was enabled — the ama-logs DaemonSet is the same Azure
  # Monitor Agent and needs the same control-plane endpoints to download its
  # Data Collection Rule. Without them the agent starts, reports healthy, and
  # logs:
  #
  #   config::error::Exception while parsing dcr : No JSON file found in the
  #   specified directory. Check if mdsd is running in MSI mode.
  #
  # then collects nothing. The failure is silent at every other level: pods are
  # 3/3 Running, the add-on reports enabled, and the Data Export rule reports
  # Enabled — but no rows reach the workspace, so no batch is ever exported and
  # the am-ContainerLogV2 hub is never created.
  application_rule_collection {
    name     = "azure-monitor-agent"
    priority = 105
    action   = "Allow"

    rule {
      name = "allow-ama-control-and-ingestion"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.1.0/27", "10.40.8.0/21"] # snet-mgmt, snet-aks
      destination_fqdns = [
        "global.handler.control.monitor.azure.com",
        "uaenorth.handler.control.monitor.azure.com",
        "*.ods.opinsights.azure.com",
        "*.oms.opinsights.azure.com",
        "*.monitoring.azure.com",
        # DCR-based ingestion endpoint. Required by the AKS agent, which runs
        # with msi_auth_for_monitoring_enabled = true and so ingests through a
        # Data Collection Endpoint rather than the legacy ODS path.
        "*.ingest.monitor.azure.com",
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

        # ── Docker Hub — BLOCKED on purpose (22 Oct 2026) ──────────────────
        # TO RE-ENABLE DOCKER HUB, UNCOMMENT THE FIVE LINES BELOW.
        # All five are needed together: registry-1 serves the manifest,
        # auth issues the anonymous pull token, and the two production.*
        # hosts serve the layer blobs. Uncommenting only some of them gets
        # the manifest and then stalls on the layers, which surfaces as
        # ImagePullBackOff with no useful reason given.
        #
        # Closed because nothing needs to PULL right now: the images are
        # already cached on the nodes and the running pods are unaffected.
        # It is not risk-free. At the time of closing, 87 running containers
        # came from Docker Hub, including the ones that carry public traffic:
        #
        #   docker.io/envoyproxy/gateway + envoy + ai-gateway-extproc
        #   nginx/nginx-ingress:3.6.2
        #   busybox:1.37.0 / 1.36      (init containers across the chart)
        #   svix/svix-server, bitnamilegacy/redis, cloudflared,
        #   clickhouse, altinity/clickhouse-operator
        #
        # So this stays harmless only while no node event forces a re-pull.
        # A node scale-out, a pod rescheduled onto a node that lacks the
        # image, or an AKS node-image upgrade will all fail to pull, and the
        # symptom appears on the workload, not here.
        #
        # The durable fix is to bring these images into ACR with
        # `az acr import` — that runs inside ACR's own service, never
        # traverses this firewall, and AKS then pulls over the private
        # endpoint. Note that tf-auth's busybox init image is hardcoded in
        # the chart by digest with no values override, so the chart has to
        # change before Docker Hub can be dropped permanently.
        #
        # "registry-1.docker.io",
        # "auth.docker.io",
        # "index.docker.io",
        # "production.cloudflare.docker.com",
        # "production.cloudfront.docker.com",
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

  # Reconciled against the deployed chart and the running workloads on
  # 22 Oct 2026 (TOKE75R). Every FQDN below was confirmed in use:
  #
  #   login.microsoftonline.com / graph.microsoft.com
  #       MICROSOFT_OIDC_CLIENT_ID is set on tf-auth
  #   accounts.google.com / oauth2.googleapis.com / www.googleapis.com /
  #   openidconnect.googleapis.com
  #       GOOGLE_OIDC_CLIENT_ID is set on tf-auth. openidconnect is the
  #       userinfo endpoint and is NOT named anywhere in the chart — its
  #       absence is what caused the Google SSO 502, so do not drop it for
  #       looking unused.
  #   api.stripe.com / files.stripe.com
  #       PLATFORM_STRIPE_SECRET_KEY is set on tf-accounts
  #   api.resend.com
  #       PLATFORM_RESEND_API_KEY is set on tf-accounts
  #
  # A caution for whoever audits this next: grepping the chart is not a
  # sufficient test. Runtime SDK endpoints never appear in configuration —
  # api.stripe.com and api.cloudflare.com both return zero chart hits and are
  # both demonstrably in use. Removal needs deny-log or workload evidence, not
  # a failed grep.
  #
  # Firewall logging is NO LONGER OFF: diag-firewall-to-soc-hub ships
  # AZFWApplicationRule denies to the azure-diagnostics event hub. To query
  # them in KQL rather than from the hub, add a second diagnostic setting
  # pointing at law-tokenfactory (logging.tf).
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
        "files.stripe.com", # Stripe hosted assets
        "api.resend.com",   # transactional email
      ]
    }
  }

  # Upstream model inference — TokenFactory's own OpenAI-compatible API.
  #
  # Xailon does NOT call the model services directly. Those run in the baremetal
  # production cluster and are only addressable there, as cluster-local names
  # such as gemma-4-31b-it-agg-h200-frontend.vllm.svc.cluster.local:8000, which
  # resolve nowhere outside that cluster.
  #
  # Instead TokenFactory is onboarded as a single upstream PROVIDER. One
  # endpoint serves the whole catalogue, so onboarding a new model needs no
  # firewall change and no model is ever exposed to the internet individually.
  #
  # An FQDN rule, not the Cloudflare IP ranges: those 15 CIDRs are Cloudflare's
  # entire public edge (~1.5M addresses fronting a large share of the web), so
  # allowing them would let these pods reach any Cloudflare-hosted site. Azure
  # Firewall matches HTTPS application rules on SNI, so the hostname is enough
  # and no TLS inspection is required.
  application_rule_collection {
    name     = "aks-model-upstream"
    priority = 112
    action   = "Allow"

    rule {
      name = "allow-tokenfactory-api"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses  = ["10.40.8.0/21"] # snet-aks
      destination_fqdns = ["api.tokenfactory.iamsaif.ai"]
    }
  }

  # Package installs for the collector VMs and the jumphost.
  #
  # kcat (Kafka CLI, used to prove the Event Hub Kafka endpoint on 9093) and
  # keepalived both come from the standard Ubuntu pockets. azure.archive is the
  # mirror the Azure Ubuntu images point at by default; archive/security are the
  # upstream fallbacks apt uses when the Azure mirror misses a pocket.
  #
  # Port 80 as well as 443: apt still fetches from the http:// sources listed in
  # /etc/apt/sources.list on these images, and an HTTPS-only rule silently
  # breaks `apt update` with a hash-sum failure rather than a clean denial.
  #
  # NOTE FOR snet-collector: this rule alone does NOT give the collectors
  # internet access. rt-collector blackholes 0.0.0.0/0 (next_hop_type = "None")
  # and nsg-collector denies VirtualNetwork outbound at priority 200, so their
  # traffic never reaches the firewall to be matched here. Both need changing
  # too — see the comment on azurerm_route_table.collector in collector.tf,
  # which anticipated exactly this ("add a firewall route and a named
  # application rule rather than opening this"). Until then this collection is
  # live only for the jumphost.
  application_rule_collection {
    name     = "collector-package-installs"
    priority = 113
    action   = "Allow"

    rule {
      name = "allow-ubuntu-apt-collector"

      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = ["10.40.5.0/28", "10.40.1.0/27"] # snet-collector, snet-mgmt
      destination_fqdns = [
        "azure.archive.ubuntu.com",
        "archive.ubuntu.com",
        "security.ubuntu.com",
        "changelogs.ubuntu.com",
        "ports.ubuntu.com"
      ]
    }

    # Cribl's package and licence endpoints. A wildcard rather than a fixed
    # host list: downloads come off cdn.cribl.io, the installer also calls the
    # main site, and Cribl moves these between subdomains without notice.
    # Azure Firewall matches HTTPS application rules on SNI, so the hostname is
    # enough and no TLS inspection is needed.
    rule {
      name = "allow-cribl"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses  = ["10.40.5.0/28", "10.40.1.0/27"]
      destination_fqdns = ["cribl.io", "*.cribl.io"]
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
  # Keycloak's outbound email — SMTP, not HTTPS.
  #
  # tf-auth configures Keycloak with KC_SMTP_HOST = smtp.resend.com on port
  # 465 (helm values.yaml:470, values-tf-prod.yaml:411). That is a different
  # path from api.resend.com in collection 107: tf-accounts uses the Resend
  # HTTPS API, Keycloak speaks SMTP. Only the first was allowed, so every
  # Keycloak email — login OTP, address verification — timed out:
  #
  #   ERROR [EmailAuthenticatorForm] Failed to send access code email
  #   Caused by: MailConnectException: Couldn't connect to host, port:
  #              smtp.resend.com, 465; timeout 10000
  #
  # observed against a real user on 21 Oct 2026, who could not log in.
  #
  # This HAS to be a network rule: Azure Firewall application rules handle
  # HTTP, HTTPS and MSSQL only, and SMTP is none of those.
  #
  # ⚠ IP ADDRESSES, NOT AN FQDN, AND THAT IS A COMPROMISE.
  # FQDNs in network rules require DNS proxy on the firewall policy, which is
  # off here — turning it on means repointing the VNet's DNS away from the
  # private resolver at 10.40.4.4 and would put private endpoint resolution at
  # risk. So the two addresses smtp.resend.com resolved to on 22 Oct 2026 are
  # pinned instead. They are AWS us-east-1 addresses and Resend publishes no
  # static IP list, so THEY CAN CHANGE WITHOUT NOTICE.
  #
  # The failure mode if they do is silent and identical to the one above:
  # Keycloak emails time out, nothing appears in the firewall's application
  # rule logs because this is a network rule, and users cannot log in. Re-check
  # with `getent hosts smtp.resend.com` if OTP delivery ever stops.
  network_rule_collection {
    name     = "aks-smtp-resend"
    priority = 114
    action   = "Allow"

    rule {
      name                  = "allow-keycloak-smtp"
      protocols             = ["TCP"]
      source_addresses      = ["10.40.8.0/21"] # snet-aks
      destination_addresses = ["54.157.71.137/32", "54.205.195.44/32"]
      destination_ports     = ["465"]
    }
  }

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
