/**
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */


variable "locations" {
  type = object({
    build = string
    ssm   = string
  })
  default = {
    build = "europe-west8"
    ssm   = "europe-west4"
  }
}

variable "network_config" {
  type = object({
    build_psa_range = optional(string, "/26")
    subnetwork      = string
    vpc_self_link   = string
  })
  default = {
    # the load balancer VIP is reserved here and both forwarding rules pin to it
    subnetwork    = "projects/ldj-dev-net-spoke-0/regions/europe-west4/subnetworks/gce"
    vpc_self_link = "projects/ldj-dev-net-spoke-0/global/networks/dev-spoke-0"
  }
}

variable "prefix" {
  type    = string
  default = "test-0"
}

variable "projects_config" {
  type = object({
    build = optional(object({
      project_id = string
      number     = optional(number)
    }))
    ssm = object({
      number     = number
      project_id = string
    })
  })
  default = {
    build = {
      project_id = "tf-playground-dev-build-pool-0"
    }
    ssm = {
      number     = 169822929449
      project_id = "tf-playground-dev-build-ssm-0"
    }
  }
}

variable "repositories_config" {
  description = "Repositories, each with its own repository-level service account and the build identities its pipelines may run as. Build identity keys become service account names as <repository>-<key>; ro and rw are the convention, matching FAST stage accounts."
  type = map(object({
    description = optional(string)
    branch_rules = optional(map(object({
      include_pattern           = string
      allow_stale_reviews       = optional(bool)
      disabled                  = optional(bool, false)
      minimum_approvals_count   = optional(number)
      minimum_reviews_count     = optional(number)
      require_comments_resolved = optional(bool)
      require_linear_history    = optional(bool)
      require_pull_request      = optional(bool)
    })), {})
    build_identities = optional(map(object({
      description = optional(string)
      # full service account ids the identity may impersonate, granted as
      # roles/iam.serviceAccountTokenCreator on each; stage 0 decides which
      # accounts accept this via a per-account delegation (README, CA pool
      # and identity section)
      impersonate_service_accounts = optional(list(string), [])
    })), {})
    initial_config = optional(object({
      default_branch = optional(string)
      gitignores     = optional(list(string))
      license        = optional(string)
      readme         = optional(string)
    }))
  }))
  nullable = false
  default = {
    test = {
      description = "Trigger behaviour tests."
      build_identities = {
        ro = {}
        rw = {}
      }
      initial_config = {
        default_branch = "main"
        readme         = "default"
      }
    }
    # the FAST VPC-SC stage, the simplest stage to put on a pipeline first;
    # the stage accounts carry the delegation that admits these grants
    vpcsc = {
      description = "FAST 1-vpcsc stage."
      build_identities = {
        ro = {
          impersonate_service_accounts = [
            "projects/ldj-prod-iac-org-0/serviceAccounts/iac-vpcsc-ro@ldj-prod-iac-org-0.iam.gserviceaccount.com"
          ]
        }
        rw = {
          impersonate_service_accounts = [
            "projects/ldj-prod-iac-org-0/serviceAccounts/iac-vpcsc-rw@ldj-prod-iac-org-0.iam.gserviceaccount.com"
          ]
        }
      }
      initial_config = {
        default_branch = "main"
      }
    }
  }
}

variable "ssm_config" {
  type = object({
    ca_pool_id      = string
    deletion_policy = optional(string, null)
    custom_host_config = object({
      api      = string
      git_http = string
      git_ssh  = string
      html     = string
    })
    psc_allowed_projects = optional(list(string))
  })
  default = {
    ca_pool_id      = "projects/ldj-dev-sec-core/locations/europe-west4/caPools/dev-ca-3"
    deletion_policy = "DELETE"
    custom_host_config = {
      api      = "api.ssm.gcp.qix.it"
      git_http = "git.ssm.gcp.qix.it"
      git_ssh  = "ssh.ssm.gcp.qix.it"
      html     = "ssm.gcp.qix.it"
    }
    # these name the projects that will OWN a consumer NEG or endpoint, not the
    # host projects of their networks: an unlisted project sits at PENDING
    # forever and reports nothing. The intended design is one chain per VPC
    # project, so these are those projects; the single chain this template
    # builds lives in the instance project, allowed implicitly. Immutable, so
    # it cannot be corrected. dr is out for another reason: another perimeter
    psc_allowed_projects = [
      "ldj-dev-net-spoke-0",
      "ldj-prod-net-landing-0",
      "ldj-prod-net-spoke-0"
    ]
  }
}
