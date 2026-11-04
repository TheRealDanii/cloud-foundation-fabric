# Secure Source Manager and Cloud Build CI/CD

This setup brings up a private Secure Source Manager instance and the Cloud Build machinery that runs pipelines from its repositories: a Cloud Build private worker pool, one repository-level service account per repository, and the build identities that pipelines run as. The instance's two Private Service Connect service attachments are outputs; the endpoints that front them in each consumer VPC are the networking stage's business, and the access path section says how.

Secure Source Manager reads a `.cloudbuild/triggers.yaml` file from each repository's default branch and starts Cloud Build itself, so no `google_cloudbuild_trigger` resource takes part.

The design targets a regulated environment. Build workers must have no external IP address. Build traffic must be attributable to the customer's VPC Service Controls perimeter: an API call made from a build step faces the same perimeter as a call made from anywhere else in the environment, and appears in the same audit logs. Those two requirements are why the pool is private and peered to the VPC, and the first apply has to demonstrate them rather than assume them — see the worker pool section.

**This is a work in progress.** The worker pool, the instance, the repositories and the build identity chain are all written and plan; the pool and the instance were applied and probed in September 2026, behind a pair of load balancers since removed from the code, and then torn down when development paused. Nothing is applied now: the plan is to complete the template, then bring everything up in one apply that tests all of it together. The sections below record the design, the prerequisites, and the points still to be resolved.

## Landing zone configuration

Three pieces of the design sit outside this configuration, because they are properties of the network, of the certificate authority and of the bootstrap stage's service accounts rather than of the project. Where a FAST landing zone is in use they belong in the networking, security and bootstrap stages; where one is not, they have to be created by whoever owns the VPC, the CA pool and the accounts a pipeline impersonates.

### The CA pool and the certificate requester grant

A private instance signs its HTTPS certificate through a Certificate Authority Service pool, and inside a VPC Service Controls perimeter that pool is mandatory. The API marks `caPool` `Optional. Immutable.` and the instance creation guide says a private instance without one gets a Google-managed certificate, while the VPC Service Controls supported products page requires a working certificate authority before you create an instance inside a perimeter. The narrower statement governs. Because the field is immutable, an instance created without a pool can never join a perimeter afterwards, which turns a wrong call here into a delete and another hour of instance creation.

The pool must allow CSR-based certificate requests, which is the default when no issuance policy is set, and the CA key must be 2048 bits. Either tier works: Secure Source Manager accepts a DevOps pool, which is what the security stage creates by default. The choice is a cost one. Enterprise is $200 per CA per month against $20 for DevOps, and what it buys is the ability to list, describe and revoke issued certificates. An instance holds one long-lived certificate, so the capability is rarely exercised and the difference is ten-fold; this playground uses DevOps, while a production landing zone that must be able to revoke should pay for Enterprise. The pool is immutable on the instance, so changing tier means recreating the instance, which takes about half an hour. The pool's project is independent of the instance's; its location is not. A pool in another region fails instance creation with a permission error that has nothing to do with permissions and leaves no trace in any log, so put the pool in the instance's region. Secure Source Manager runs in far fewer regions than Certificate Authority Service, and this is where that bites.

The grant that makes it work is `roles/privateca.certificateRequester` for the Secure Source Manager service agent of the *instance* project, placed on the CA pool. Project scope is acceptable for this role. The member string embeds the instance project's number, which does not exist until the project does, so whatever creates the project places the grant rather than this configuration. In the project factory that is `service_agents_project_bindings`, which exists for this shape — a project's own service agents granted roles on projects and folders it does not own:

```yaml
service_agents_project_bindings:
  ssm-certificate-requester:
    service: sourcemanager
    project: $project_ids:sec-core-0
    role: roles/privateca.certificateRequester
```

Enabling `securesourcemanager.googleapis.com` through the project factory is enough to create the service agent and attach `roles/securesourcemanager.serviceAgent` to it, because the project module carries `sourcemanager` as a primary service agent. Google's guide creates it by hand with `gcloud beta services identity create` and grants the role separately; you do not need to. The agent must exist before the first instance is created or creation fails.

The grant lands in a project the project factory does not own, so the factory's own identity needs the right to make it. In FAST that is a delegated, conditioned `roles/resourcemanager.projectIamAdmin` on the CA pool's project or on its parent folder, set where that folder is defined:

```yaml
iam_bindings:
  project_factory:
    role: roles/resourcemanager.projectIamAdmin
    members:
      - $iam_principals:service_accounts/iac-0/iac-pf-rw
    condition:
      title: Project factory delegated IAM grant.
      expression: |
        api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([
          'roles/privateca.certificateRequester',
          'roles/privateca.auditor'
        ])
```

Include `roles/privateca.auditor` in the same condition. The build identities need it on the CA pool's project to fetch the certificate chain, and putting both roles in one delegation avoids a second one later.

The auditor grant exists for one call. The instance's certificate is signed by our own CA, so nothing on a worker trusts it; before it can clone, a build runs `gcloud privateca pools get-ca-certs`, writes the chain and points git at it. A probe on 2026-09-14 confirmed both halves of that: a worker with no such grant is denied `privateca.caPools.get` and cannot obtain the chain, and a client that does hold the chain verifies the instance's certificate cleanly where a default trust store fails it. Auditor is read-only across the CA project's resources, which is wider than that one fetch, and it is granted per build identity on a project this configuration does not own. Two things would be better. A custom role holding only the permission `get-ca-certs` needs would keep the shape and narrow the grant. Publishing the bundle to a bucket, ideally a managed folder holding just this chain, would remove the grant and the delegation behind it entirely, since the chain is a public artifact and reading it needs nothing on the CA. Neither is done here; the second is on the TODO list as stage work.

The build identities take `roles/privateca.auditor` from this configuration, through `iam_project_roles` on `iam-service-account`, and the delegation on the CA pool's project names this configuration's service account rather than the factory's. The factory cannot place it: the identities do not exist until this configuration creates them.

### The delegation that lets build identities impersonate stage accounts

One more grant crosses an ownership line, and it is the one that makes a pipeline useful: `roles/iam.serviceAccountTokenCreator` on the Terraform service accounts a build identity impersonates. For application pipelines those accounts sit next to the application and nothing special is needed. For FAST stages they belong to the bootstrap stage, in the `iac-0` project, and this configuration's automation account has no right to set IAM on them.

Both ends of that edge are known here and nowhere else — the build identities are created here, the stage accounts are named in `repositories_config` — so this is where the grant is placed, and the bootstrap stage decides which of its accounts accept it. That decision is a delegation on each account rather than on the project: a conditioned binding on the service account resource, allowing this configuration's automation account to modify only `roles/iam.serviceAccountTokenCreator` on that one account. The set of stage accounts a build can ever impersonate is then the list of accounts carrying the binding, declared by their owner next to their definition, and an `impersonate_service_accounts` entry naming any other account fails the apply with a permission error, which is the right failure.

The role in that binding has to be a custom one. The only predefined role carrying `iam.serviceAccounts.setIamPolicy` is `roles/iam.serviceAccountAdmin`, which also carries delete, disable and key management, and the `modifiedGrantsByRole` condition does not restrain those: the attribute is only present on `setIamPolicy` requests, so on anything else `getAttribute(..., [])` yields an empty list and `hasOnly` passes. This is why Google's delegation examples pair the condition with `projectIamAdmin`, a role holding nothing but policy permissions. The equivalent for service accounts is an organization custom role with `iam.serviceAccounts.get`, `iam.serviceAccounts.getIamPolicy` and `iam.serviceAccounts.setIamPolicy`. In the bootstrap stage data that is one custom role file plus, per impersonable account, one binding:

```yaml
# organization/custom-roles/service_account_iam_admin.yaml
name: serviceAccountIamAdmin
includedPermissions:
  - iam.serviceAccounts.get
  - iam.serviceAccounts.getIamPolicy
  - iam.serviceAccounts.setIamPolicy
```

```yaml
# projects/core/iac-0.yaml, on each stage account builds may impersonate
service_accounts:
  iac-networking-ro:
    display_name: IaC service account for networking (read-only).
    iam_bindings_additive:
      ssm-build-delegation:
        role: $custom_roles:service_account_iam_admin
        member: $iam_principals:ssm-rw
        condition:
          title: SSM build identities delegation.
          expression: |
            api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', [])
            .hasOnly(['roles/iam.serviceAccountTokenCreator'])
```

`ssm-rw` is a static `context.iam_principals` entry in the bootstrap stage's `defaults.yaml`, holding the automation account's email, since that account is created by the project factory and the bootstrap stage does not otherwise know it. The ordering is the natural one: the factory creates the account, the bootstrap stage is reapplied with the bindings, and this configuration can then place the grant.

### The private DNS zone for the instance hostnames

A private Secure Source Manager instance publishes its hostnames under `REGION.p.sourcemanager.dev`, and those names resolve nowhere useful by default. They appear in neither Private Google Access VIP domain list, so no private access configuration reaches a repository. A private zone attached to the VPC is the only way clients resolve them.

With the generated names the zone holds four A records under `REGION.p.sourcemanager.dev.`: `INSTANCE_ID-PROJECT_NUMBER-api`, `INSTANCE_ID-PROJECT_NUMBER-git` and the bare `INSTANCE_ID-PROJECT_NUMBER` all point at whatever fronts the HTTP service attachment, and `INSTANCE_ID-PROJECT_NUMBER-ssh` at whatever fronts the SSH one. What fronts them is the subject of the access path section below.

This configuration sets custom hostnames instead, through `custom_host_config` on the instance, which replaces the generated names with four of your own. The API requires all four and the CA pool signs their certificate, which is a second reason the pool is mandatory here. The zone then covers your own domain, with `api`, `git` and the apex resolving to the HTTP endpoint and `ssh` to the SSH one.

Custom hostnames are worth the extra field for two reasons. The generated names embed the instance id and the project number, and since nothing about an instance can change after creation, a rebuild produces new hostnames in every DNS record, clone URL, credential helper and CI configuration that referenced them. Names you own survive a rebuild: the records repoint and nothing downstream changes.

The second reason applies to anyone running more than one region. An instance is regional and immutable, so a second region means a second instance, and with generated names it also means a second DNS suffix — `REGION.p.sourcemanager.dev.` is per-region, so each region needs its own private zone, added to the landing zone every time a region is added. Custom hostnames let every instance live under one parent domain, `ew4.ssm.example.com` and `ew2.ssm.example.com` beneath `ssm.example.com`, so one zone covers all of them and adding a region touches no landing zone configuration. Each instance still needs its own CA pool grant, its own service attachments and its own endpoints.

The records point at the endpoint addresses, and since each consumer VPC has its own pair of endpoints the answer differs per VPC: a response policy rule per VPC, or a private zone per VPC, both owned by the networking stage next to the endpoints themselves. The names are the same everywhere; only the addresses differ, which is what makes one hostname set serve every VPC. Where a single network-wide answer is wanted instead, the load balancer alternative in the access path section is what provides it, at the cost of the load balancers.

The build workers need one more thing, because they sit on the producer side of a private service access peering and peering carries routes but not DNS. A worker resolves against the producer network's resolver and never sees the VPC's zones, so the route to the instance works while `git clone` fails at name resolution. The fix is a peered DNS domain on the peering — `peered_domains` inside `psa_configs` in `net-vpc` — naming the hostname suffix, `ssm.gcp.qix.it.` here.

Creating the zone in this configuration's own project instead is possible but costs more than it looks. Attaching a private zone to a VPC in another project is a cross-project bind, so the identity running Terraform needs `dns.networks.bindPrivateDNSZone` on the host project on top of `compute.networks.get`, and neither comes with any role you would otherwise grant it. No predefined role carries only the bind permission, so this means a custom role on the host project. Prefer the landing zone's DNS design where one exists.

### The private service access peering for the Cloud Build private pool

A Cloud Build private pool never runs in your VPC; the question is only how its workers reach it. With private service access, which is what Google's guide uses and what this configuration does, the workers run in a Google-managed producer VPC joined to yours by a service networking peering over a range you allocate. With Private Service Connect each worker would instead get an interface in a subnet of your own VPC through a network attachment. The second is the better design — no range, no exported routes, and the workers resolve against your VPC's resolver so nothing has to be forwarded — and it is not available: the API refuses the pool with `Private Service Connect feature is unavailable`, an allowlist that Terraform and gcloud both hide by silently creating a pool with no network at all. The evidence is in [SSM-CB.md](SSM-CB.md); this configuration switches to it when the allowlist opens, and that switch is one block on the pool resource plus the landing zone changes.

The peering needs a range, the exported subnet routes so the workers reach addresses in the VPC, and the peered DNS domain from the previous section:

```yaml
psa_configs:
  - ranges:
      psa-build: 10.8.200.0/24
    export_routes: true
    peered_domains:
      - ssm.gcp.qix.it.
```

Google's guide also asks for `--no-export-subnet-routes-with-public-ip`, which `net-vpc` does not express; check the peering after the first apply. The range is regional to nothing — the peering is on the VPC — so the pool's region need not be the instance's. Two consequences follow:

- `no_external_ip` on the pool maps to the peering's egress option and is what keeps the workers off the internet. There is no backstop: the workers run in a Google-managed tenant project in Google's own organisation, where `compute.vmExternalIpAccess` and every other policy of ours has no reach, and a pool with public egress was created here without complaint. A private-egress worker reaches Google APIs through Private Google Access and nothing else; a build that needs the internet needs a different answer.
- The workers arrive from the peered range for firewall purposes, so ingress rules that admit them name `10.8.200.0/24` rather than a subnet.

Whether the workers' API traffic is attributed to your perimeter is the other regulated requirement, and it is a property to prove rather than assume. An earlier private service access pool showed the Google-side tenant project treated as inside the perimeter of the VPC's project, and the first build should confirm it: have a build step call an API the perimeter denies and check that the violation lands in your perimeter's audit logs with the worker as the source.

The pool needs no service account of its own. An identity is named per build, in the triggers file, and the pool only has to admit it. A build identity does need `roles/logging.logWriter`, and that is less optional than it looks: a build running as a user-managed service account has no default log destination, so it must either write to Cloud Logging and say so with `CLOUD_LOGGING_ONLY`, or name a bucket. With neither, the build fails before it runs a step.

## The access path to the instance

A private instance publishes two Private Service Connect service attachments, one for HTTP and one for SSH, and both are computed rather than configured: the instance has no notion of a consumer and no way to create one. This configuration exposes them in the `service_attachments` output and creates nothing in front of them. Consumers are the networking stage's business, because the address a client reaches the instance at is a property of the client's VPC, not of the instance's project.

### Endpoints, created by the networking stage

Each consumer VPC gets two Private Service Connect endpoints, one per attachment. An endpoint is a forwarding rule aimed at an attachment with an address from one of the VPC's subnets, and it carries no ports: everything sent to the address goes to the attachment, so HTTP and SSH cannot share an address and each VPC ends up with two. The hostnames already allow for it, `api`, `git_http` and `html` resolving to the HTTP endpoint and `git_ssh` to the SSH one.

In the networking stage the endpoints are two `addresses.psc` entries in the VPC's `.config.yaml`, with the attachments named through the `service_attachments` context, whose values are static entries in the stage's `defaults.yaml` copied from this configuration's output after the instance is created:

```yaml
# 2-networking defaults.yaml
context:
  service_attachments:
    ssm-http: projects/abcdef-tp/regions/europe-west4/serviceAttachments/http-psc
    ssm-ssh: projects/abcdef-tp/regions/europe-west4/serviceAttachments/ssh-psc
```

```yaml
# 2-networking vpcs/dev/.config.yaml
addresses:
  psc:
    ssm-http:
      region: $locations:ssm
      subnet_self_link: $subnets:dev/europe-west4/gce
      service_attachment:
        psc_service_attachment_link: $service_attachments:ssm-http
        global_access: true
    ssm-ssh:
      region: $locations:ssm
      subnet_self_link: $subnets:dev/europe-west4/gce
      service_attachment:
        psc_service_attachment_link: $service_attachments:ssm-ssh
        global_access: true
```

`global_access` lets clients in other regions of the same VPC use the endpoint, which matters because Secure Source Manager runs in eleven regions and only two of them are in Europe, so the instance usually cannot sit in the region everything else uses. An endpoint is also reachable from on-premises over VPN or Interconnect. What it is not reachable across is VPC peering, by design; that case is covered below.

The attachments move to a new tenant project on every instance rebuild, so the two context entries are the one thing downstream that has to be updated after a rebuild, and the hostnames are what keep everything else stable. Endpoint addresses are the ones the DNS records point at, and since every VPC has its own, DNS is per VPC: a response policy rule in each VPC, or a private zone per VPC, rather than the single hub zone the generated hostnames would otherwise suggest. The networking stage owns both.

Two things must be right at instance creation because they are immutable. `psc_allowed_projects` is keyed on the project that owns the consumer endpoint, not on the host project of the network it connects from; tested on 2026-09-14, a consumer created in a project outside the list, on a Shared VPC whose host project is inside it, sits at `pscConnectionStatus: PENDING` and never connects, while the same consumer in a listed project is `ACCEPTED` in seconds. With endpoints created by the networking stage in each VPC's own project, the list is the VPC projects, and naming a project costs nothing, so be generous. The failure mode deserves its own warning, because nothing reports it: the apply is clean and the only symptom is that traffic never arrives. The status lives on the forwarding rule's `pscConnectionStatus` and it is the first thing to read when an endpoint is silent.

### Clients behind a peering, and the load balancer alternative

A Private Service Connect endpoint does not serve clients that reach the VPC over VPC peering, and the build workers are exactly that: a private pool runs in a Google-managed producer network joined to yours by a private service access peering. For the workers to reach the instance through their peering, the VPC needs something whose address the peering carries, and that is an internal load balancer's forwarding rule rather than an endpoint.

This was the design until 2026-11-04 and it was built and probed: two regional internal proxy load balancers in the dev VPC, each a PSC network endpoint group on one attachment, a backend service, a target TCP proxy and a forwarding rule, on 443 and 22, sharing one address reserved as `SHARED_LOADBALANCER_VIP` since the rules differ by port, with `global_access` on. A worker on the peering and a bastion in the hub both resolved all four hostnames to that address and opened both ports on it; the handshake returned the instance's own certificate, signed by our CA and carrying the four custom names. The proxy is layer 4 and terminates the TCP connection but not the TLS session, which is why custom hostnames need the CA pool rather than the load balancer, and why SNI cannot collapse both services onto one port. A PSC NEG backend accepts only the `UTILIZATION` balancing mode. [SSM-CB.md](SSM-CB.md) has the full record.

It was dropped from the code because the peering constraint is a playground artefact rather than a property of the design. The pool's own Private Service Connect path, where each worker gets an interface in a subnet of your VPC through a network attachment, is the better pool design and is behind an allowlist; with it, the workers are in the VPC and use the same endpoints as everything else. Where a landing zone is stuck on private service access for the pool, the load balancer pair is the answer for that one VPC, built by the networking stage with `net-lb-proxy-int` against the same attachments, and the endpoint model stays for every other VPC. A hub and spoke design built on peering has the same need in the hub; one built on NCC does not, since PSC propagated connections carry endpoints across spokes.

## Settled points and provider gaps

Two questions this document used to leave open were answered by building the thing; they stay here because the answers are not where a reader would look for them. What is still open is in [TODO.md](TODO.md).

- **Who places the grants on identities this configuration does not own.** `roles/privateca.auditor` comes from here under a delegation on the CA project, and `roles/iam.serviceAccountTokenCreator` on a stage's Terraform accounts also comes from here, under a per-account delegation declared in the bootstrap stage. See the CA pool and delegation sections.
- **What a consumer in a Shared VPC service project needs.** Learned with the load balancers and true of endpoints too: `roles/compute.networkUser` at host project level for the identity creating them and for the compute service agent, which is where that role belongs. Subnet-scoped grants are not the narrower form of this — IAM composes, so a subnet binding adds to a project binding rather than restricting it, and limiting a service project to particular subnets is an organisation policy question rather than an IAM one.
- **Provider gaps.** Pin `hashicorp/google` at 7.44.0 or later: `google_secure_source_manager_repository` gained `service_account` there, and that field is what makes a repository-level service account something the configuration enforces rather than something an operator remembers. `google_secure_source_manager_branch_rule` lacks `requiredStatusChecks` and `requireCodeOwnerApproval`, both of which the API has, so the merge gate and the code owner requirement are set in the web interface until the provider carries them. `google_developer_connect_connection` still has no Secure Source Manager block, which rules out the Developer Connect alternative to the network path above.

## Security note

A person who can commit to a repository's default branch chooses both the identity a build runs as and the event that starts it, because both live in the triggers file. The build steps come from the commit that fired the event, so any `pull_request` trigger is a standing grant of its named identity to everyone who can open a pull request against that repository. The full escalation analysis lives in [SSM-CB.md](SSM-CB.md); the three boundaries it leaves are:

- isolation between repositories comes from the set of act-as edges leaving each repository's service account, which is why every repository gets its own and why `roles/iam.serviceAccountUser` is granted on the service account resource and never on a project
- which identities a repository can name at all comes from who may commit to the default branch, so branch protection and CODEOWNERS carry weight that IAM carries elsewhere
- what a `pull_request` trigger's identity may do comes from that identity's own permissions and nothing else, so it has to be safe in the hands of everyone who can open a pull request

The last one is stricter than it sounds: a plan identity that reads Terraform state hands that state to every pull request author, and state files carry secrets in practice.

### Two branch rule settings are made by hand

The second boundary is the one the provider cannot fully express today. `google_secure_source_manager_branch_rule` carries neither `requiredStatusChecks` nor `requireCodeOwnerApproval`, although the REST resource `projects.locations.repositories.branchRules` has both, so Terraform can create the rule and protect the branch but cannot set the merge gate or make CODEOWNERS binding. Set both in the web interface, per repository, after the branch rule is created, and set them again if the rule is recreated:

- **Required status checks** — add the build's status check context, so a failing build blocks the merge. Without it the build runs and reports and nothing stops a merge that ignores it.
- **Require code owner approval** — without it CODEOWNERS is advisory, and since committing to the default branch is what decides which identities a repository may name, an advisory CODEOWNERS leaves the second boundary resting on branch protection alone.

Until the provider catches up these are operational steps, not configuration, so nothing detects their absence. Check them when a repository is added. Closing the gap upstream is recorded as follow-up work in [TODO.md](TODO.md).
