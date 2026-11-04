# The sketch

The parts of this configuration that are not live yet. They were comments inside `main.tf` until 2026-09-12, which left that file mostly prose; it now carries only code that runs. Reasoning is in [README.md](README.md), open questions in [TODO.md](TODO.md), observed behaviour and caveats in [SSM-CB.md](SSM-CB.md).

Attribute names below were taken from each module's `variables.tf` where they were verified, and marked TODO where they were not. Nothing here is expected to plan.

As of 2026-09-12 the instance and worker pool blocks are superseded by `ssm-instance.tf` and `build-pool.tf`, as of 2026-09-13 the load balancer block by `ssm-load-balancers.tf`, and as of 2026-11-04 the identity blocks by `ssm-repositories.tf` and the `repositories` and `iam` attributes in `ssm-instance.tf`, which differ from the version below in one way: identities are nested under their repository in a single `repositories_config` variable rather than a separate `build_identities` map. Every block here is now superseded; the file stays as the record of the shape the code was written against and of what is owned elsewhere.

The configuration spans two projects with one provider, because one automation service account, `dev-build-ssm-0-rw`, holds IAM in both. The instance project holds the instance, its repositories, their per-repository service accounts and the two internal proxy load balancers fronting the service attachments, in `europe-west4` — Secure Source Manager runs in eleven regions and only two are in Europe. The build project holds the private worker pool and the build identities the triggers file names, in `europe-west8`, the primary location for everything else here. The regions differ on purpose, and `global_access` on the forwarding rules is what lets a pool in one region reach a load balancer in the other across the same VPC.

## Blocks

```hcl
# ------------------------------------------------------------------------
# source: instance and repositories
# ------------------------------------------------------------------------

# Superseded by ssm-instance.tf except for the repositories and iam
# attributes, which are the part still to be written there.
module "ssm-instance" {
  source     = "../../../modules/secure-source-manager-instance"
  project_id = module.ssm-project.project_id
  location   = var.locations.ssm
  # the instance id ends up inside every hostname, DNS record and clone URL,
  # and nothing about an instance can change after creation
  instance_id     = "${local.prefix}dev-0"
  deletion_policy = var.ssm_config.deletion_policy
  private_configs = {
    is_private = true
    # projects/ldj-dev-sec-core/locations/europe-west4/caPools/dev-ca-3 in the
    # playground. The pool's project is independent of the instance's, its
    # location is not: the pool must sit in the instance's region
    ca_pool_id = var.ssm_config.ca_pool_id
    # names the projects that will own a consumer NEG or endpoint; immutable
    psc_allowed_projects = var.ssm_config.psc_allowed_projects
    # custom hostnames under ssm.gcp.qix.it, in place of the generated ones
    # under europe-west4.p.sourcemanager.dev. The generated names embed the
    # instance id and the project number, so they change on any rebuild;
    # these are ours and survive one. All four are required by the API, and
    # the CA pool above signs their certificate.
    custom_host_config = var.ssm_config.custom_host_config
  }
  repositories = {
    for k, v in var.repositories : k => {
      description     = v.description
      branch_rules    = v.branch_rules
      service_account = module.repo-sa[k].email
      iam = {
        # build identities this repository's pipelines may run as get
        # repoReader here, on the repository, never on the project
        "roles/securesourcemanager.repoReader" = [
          for sa in v.build_identities : module.build-sa[sa].iam_email
        ]
      }
    }
  }
  # every build identity needs instanceAccessor on the instance itself
  iam = {
    "roles/securesourcemanager.instanceAccessor" = [
      for k, v in module.build-sa : v.iam_email
    ]
  }
}

# ------------------------------------------------------------------------
# identity
# ------------------------------------------------------------------------

# One BYOSA per repository, in the instance project. iam_sa_roles carries the
# act-as edges: a map of target service account id to roles, granted on the
# target service account resource rather than on a project, which is the rule
# the isolation requirement rests on.
#
# These live in the instance project while the builds they create run in the
# build project, which is why dev-build-ssm-0 disables
# iam.disableCrossProjectServiceAccountUsage. Only the project hosting the
# service account needs that.
module "repo-sa" {
  source     = "../../../modules/iam-service-account"
  for_each   = var.repositories
  project_id = module.ssm-project.project_id
  name       = "ssm-repo-${each.key}"
  prefix     = var.prefix
  # the Secure Source Manager service agent mints tokens for this BYOSA. The
  # member string comes from the reused project module in main.tf, which
  # derives it from the project number without an API call (TODO.md, settled
  # 2026-09-15).
  iam = {
    "roles/iam.serviceAccountTokenCreator" = [
      module.ssm-project.service_agents["sourcemanager"].iam_email
    ]
  }
  iam_sa_roles = {
    for sa in each.value.build_identities :
    module.build-sa[sa].id => ["roles/iam.serviceAccountUser"]
  }
  # the BYOSA creates builds in the build project, so its Cloud Build roles
  # land there rather than here
  iam_project_roles = {
    (local.build_project.project_id) = [
      "roles/cloudbuild.builds.editor",
      "roles/cloudbuild.workerPoolUser",
      "roles/serviceusage.serviceUsageConsumer",
    ]
  }
}

# The build identities the triggers file names, in the build project
# alongside the pool they run on. build-sa-test in main.tf is the one-off
# ancestor of this block and goes when it lands.
module "build-sa" {
  source     = "../../../modules/iam-service-account"
  for_each   = var.build_identities
  project_id = local.build_project.project_id
  name       = each.key
  prefix     = var.prefix
  iam_project_roles = {
    (local.build_project.project_id) = [
      "roles/logging.logWriter",
      "roles/cloudbuild.workerPoolUser",
    ]
    # roles/privateca.auditor on the CA pool's project, to fetch the
    # certificate chain before cloning. Placed from here: the delegated,
    # conditioned projectIamAdmin on dev-sec-core names this configuration's
    # automation account and allows exactly this role and
    # certificateRequester (README, CA pool section; applied 2026-09-12,
    # never exercised yet). The project id is the second path element of
    # var.ssm_config.ca_pool_id; the local that splits it out is not written.
    (local.ca_pool_project_id) = ["roles/privateca.auditor"]
  }
  # impersonation of the terraform service accounts the pipeline uses
  iam_sa_roles = each.value.impersonate_service_accounts
}

# ------------------------------------------------------------------------
# build: private worker pool
# ------------------------------------------------------------------------

# Raw resource by decision: Fabric does not write modules for single
# resources. Live in build-pool.tf, with the size hardcoded; the
# worker_pool_config variable below is the shape it takes when it becomes
# configurable.
#
# The workers reach the VPC over a private service access peering on the
# psa-build range, created by the networking stage. Private Service Connect
# through a network attachment was the first choice and is gated; see
# SSM-CB.md. Name resolution needs the peered_domains entry on that peering,
# since a worker on the producer side does not see the VPC's zones.
resource "google_cloudbuild_worker_pool" "default" {
  project  = local.build_project.project_id
  name     = "${local.prefix}default-0"
  location = var.locations.build
  worker_config {
    disk_size_gb   = var.worker_pool_config.disk_size_gb
    machine_type   = var.worker_pool_config.machine_type
    no_external_ip = true
  }
  network_config {
    peered_network          = var.network_config.vpc_self_link
    peered_network_ip_range = var.network_config.build_psa_range
  }
}
```

## Owned elsewhere

Listed so the boundary is explicit.

- **2-security** — the CA pool and CA, `dev-ca-3` in `ldj-dev-sec-core` (`dev-ca-0` to `dev-ca-2` are burned ids, see SSM-CB.md), plus `roles/privateca.certificateRequester` for the instance project's Secure Source Manager service agent. The factory places that one through `service_agents_project_bindings`, because the member string embeds the project number. Already in `dev-build-ssm-0.yaml`. The same project carries the delegated `projectIamAdmin` that lets this configuration place `roles/privateca.auditor` on the build identities.
- **2-networking** — the `europe-west4/gce` subnet the forwarding rule addresses come from, the proxy-only subnet `europe-west4/ilb-l7-ew4`, and the private service access peering on `psa-build` at `10.8.200.0/24` with `ssm.gcp.qix.it.` as a peered domain.
- **2-networking DNS** — the `ssm.gcp.qix.it.` private zone in the hub, `pvt-ssm.yaml` under `net-core-0`. Kept out because the addresses are outputs here and the records are owned there; the records are filled in after the first apply.
