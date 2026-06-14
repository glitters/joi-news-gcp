resource "google_artifact_registry_repository" "repository" {
  provider      = google-beta
  location      = var.region
  repository_id = "images"
  description   = "Repository for storing images"
  format        = "DOCKER"
}

# grant default compute instance user ability to read from Artifact Registry
data "google_compute_default_service_account" "default" {}
resource "google_artifact_registry_repository_iam_member" "viewer" {
  provider   = google-beta
  location   = "us-central1"
  repository = google_artifact_registry_repository.repository.name
  role       = "roles/artifactregistry.admin"
  member     = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

locals {
  gcr_url = "us-central1-docker.pkg.dev/${var.project}/images"
}

resource "local_file" "gcr" {
  filename = "${path.module}/../gcr-url.txt"
  content  = local.gcr_url
}

output "repository_base_url" {
  value = local.gcr_url
}
