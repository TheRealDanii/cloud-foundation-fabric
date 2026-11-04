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

# tfdoc:file:description Repository service accounts and build identities.

locals {
  # flattened <repository>/<identity> map, the key used by module.build-sa
  build_identities = merge([
    for rk, rv in var.repositories_config : {
      for ik, iv in rv.build_identities : "${rk}/${ik}" => merge(iv, {
        repository = rk
        name       = "${rk}-${ik}"
      })
    }
  ]...)
  # the CA pool project, where build identities need auditor to fetch the
  # chain before cloning; the grant is allowed by a delegation there
  ca_pool_project_id = split("/", var.ssm_config.ca_pool_id)[1]
}

# one BYOSA per repository, in the instance project; its act-as edges are the
# whole set of identities a committer to that repository can choose from, so
# serviceAccountUser is granted on each build identity and never on a project

module "repo-sa" {
  source     = "../../../modules/iam-service-account"
  for_each   = var.repositories_config
  project_id = module.ssm-project.project_id
  name       = "ssm-repo-${each.key}"
  prefix     = var.prefix
  # the SSM service agent mints tokens for the BYOSA
  iam = {
    "roles/iam.serviceAccountTokenCreator" = [
      module.ssm-project.service_agents["sourcemanager"].iam_email
    ]
  }
  iam_sa_roles = {
    for ik, iv in each.value.build_identities :
    module.build-sa["${each.key}/${ik}"].id => [
      "roles/iam.serviceAccountUser"
    ]
  }
  # builds are created in the build project, so the Cloud Build roles land
  # there rather than in the instance project
  iam_project_roles = {
    (local.build_project.project_id) = [
      "roles/cloudbuild.builds.editor",
      "roles/cloudbuild.workerPoolUser",
      "roles/serviceusage.serviceUsageConsumer",
    ]
  }
}

# the identities a repository's triggers file names, in the build project
# alongside the pool they run on

module "build-sa" {
  source      = "../../../modules/iam-service-account"
  for_each    = local.build_identities
  project_id  = local.build_project.project_id
  name        = each.value.name
  prefix      = var.prefix
  description = each.value.description
  iam_project_roles = {
    (local.build_project.project_id) = [
      "roles/cloudbuild.workerPoolUser",
      "roles/logging.logWriter",
    ]
    (local.ca_pool_project_id) = [
      "roles/privateca.auditor"
    ]
  }
  # the stage or application accounts this identity impersonates; whether
  # the target account accepts this is decided where it is defined, through
  # a delegation naming this configuration's automation account
  iam_sa_roles = {
    for sa in each.value.impersonate_service_accounts :
    sa => ["roles/iam.serviceAccountTokenCreator"]
  }
}
