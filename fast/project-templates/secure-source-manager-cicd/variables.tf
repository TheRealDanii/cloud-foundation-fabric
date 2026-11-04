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

variable "build_pool_config" {
  description = "Cloud Build private worker pool. The pool peers with the VPC over private service access, on a range of the given size carved from the VPC's PSA allocation; workers have no external IP."
  type = object({
    disk_size_gb   = optional(number, 100)
    machine_type   = optional(string, "e2-standard-2")
    peered_network = string
    psa_range_size = optional(string, "/26")
  })
  nullable = false
}

variable "locations" {
  description = "Regions for the build pool and for the instance. The instance region must be one where Secure Source Manager runs, and the CA pool must be in the same region as the instance."
  type = object({
    build = string
    ssm   = string
  })
  nullable = false
}

variable "name" {
  description = "Base name for the instance and the build pool, prefixed with the prefix."
  type        = string
  nullable    = false
  default     = "ssm-0"
}

variable "prefix" {
  description = "Optional prefix for resource names."
  type        = string
  default     = null
  validation {
    condition     = var.prefix != ""
    error_message = "Prefix cannot be empty, please use null instead."
  }
}

variable "projects_config" {
  description = "Instance project, with its number so the Secure Source Manager service agent can be named without an API call, and optional build project for the pool and the build identities; the instance project is used for both when build is null."
  type = object({
    build = optional(object({
      project_id = string
    }))
    ssm = object({
      number     = number
      project_id = string
    })
  })
  nullable = false
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
      # roles/iam.serviceAccountTokenCreator on each; the owner of the target
      # account decides whether it accepts this, via a delegation naming this
      # configuration's automation account (README, delegation section)
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
  default  = {}
}

variable "ssm_config" {
  description = "Instance configuration. The CA pool and psc_allowed_projects are immutable: the pool must be in the instance region, and the allowed projects are the projects that will own consumer endpoints, which with endpoints created by the networking stage are the VPC projects."
  type = object({
    ca_pool_id = string
    custom_host_config = object({
      api      = string
      git_http = string
      git_ssh  = string
      html     = string
    })
    deletion_policy      = optional(string)
    psc_allowed_projects = optional(list(string))
  })
  nullable = false
}
