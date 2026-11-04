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

output "build_identities" {
  description = "Build identity service accounts, keyed <repository>/<identity>; the email is what a triggers file names and what a delegation on an impersonated account refers to."
  value = {
    for k, v in module.build-sa : k => {
      email = v.email
      id    = v.id
    }
  }
}

output "build_pool_id" {
  description = "Cloud Build private worker pool id."
  value       = google_cloudbuild_worker_pool.default.id
}

output "repository_service_accounts" {
  description = "Repository-level service account emails, by repository."
  value       = { for k, v in module.repo-sa : k => v.email }
}

output "ssm_lb_address" {
  description = "Shared VIP of the two load balancers, for the ssm.gcp.qix.it A records."
  value       = module.ssm-lb-ip.internal_addresses[local.ssm_lb_ip].address
}

output "ssm_instance" {
  description = "Instance id, hostnames, service attachments and repository ids."
  value = {
    id              = module.ssm-instance.instance_id
    hosts           = module.ssm-instance.host_config
    http_attachment = module.ssm-instance.http_service_attachment
    ssh_attachment  = module.ssm-instance.ssh_service_attachment
    repository_ids  = module.ssm-instance.repository_ids
  }
}
