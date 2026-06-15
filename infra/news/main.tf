locals {
  gcr_url = "us-central1-docker.pkg.dev/${var.project}/images"
}

# the dedicated service account that the compute instances will use
resource "google_service_account" "joi-news-instances" {
  account_id   = "${var.prefix}-compute"
  display_name = "${var.prefix} Service Account"
}

# grant the compute service account read access to Artifact Registry
resource "google_artifact_registry_repository_iam_binding" "viewer" {
  provider   = google-beta
  repository = "images"
  location   = "us-central1"
  role       = "roles/artifactregistry.reader"                                   ### Change to roles/artifactregistry.reader
  members = [
    "serviceAccount:${google_service_account.joi-news-instances.email}",
  ]
}

data "google_compute_network" "default" {
  name = "vpc-${var.prefix}"
}

data "google_compute_subnetwork" "subnet" {
  name = "subnet-${var.prefix}"
}

### Front end server
resource "google_compute_instance" "front_end" {
  name         = "${var.prefix}-front-end"
  machine_type = var.machine_type
  zone         = "${var.region}-a"
  tags         = ["web"]

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-125-lts"
    }
  }

  metadata_startup_script = templatefile("${path.module}/provision-front_end.sh", {
    docker_image         = "${local.gcr_url}/front_end:latest"
    quote_service_url    = "http://${google_compute_instance.quotes.network_interface.0.network_ip}:8082"        ### Change to network_ip and also https
    newsfeed_service_url = "http://${google_compute_instance.newsfeed.network_interface.0.network_ip}:8081"      ### Change to network_ip and also https
    static_url           = "https://storage.googleapis.com/${google_storage_bucket.news.name}"
  })

  network_interface {
    subnetwork = data.google_compute_subnetwork.subnet.self_link

    access_config {
      // Ephemeral IP
    }
  }
  service_account {
    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    email  = google_service_account.joi-news-instances.email
    scopes = var.service_account_scopes
  }
}

# # Allow public access to the front-end server
resource "google_compute_firewall" "front_end" {
  name    = "front-end-firewall"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["80"]                                                             ### Consider to change to port 80
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web"]
}
### end of front-end

### Quotes service deploy


resource "google_compute_firewall" "quotes" {
  name    = "quotes-firewall"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["8082"]
  }

  source_ranges = ["10.10.0.0/16"]                                                     ### Consider to change to 10.5.0.0/16, private IP addressing
  target_tags   = ["quotes"]
}

resource "google_compute_instance" "quotes" {
  name         = "${var.prefix}-quotes"
  machine_type = var.machine_type
  zone         = "${var.region}-a"
  tags         = ["quotes"]

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-125-lts"
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.subnet.self_link

    access_config {
      // Ephemeral IP
    }
  }

  metadata_startup_script = templatefile("${path.module}/provision-quotes.sh", {
    docker_image = "${local.gcr_url}/quotes:latest"
  })

  service_account {
    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    email  = google_service_account.joi-news-instances.email
    scopes = var.service_account_scopes
  }
}

### end of quotes service

### Newsfeed service deploy


resource "google_compute_instance" "newsfeed" {
  name         = "${var.prefix}-newsfeed"
  machine_type = var.machine_type                       ### f1-micro instances - shares vCPU. Under load it will throttle hard. Conside to use Cloud Run
  zone         = "${var.region}-a"                      ### Single zone deployment - no availability or load distribution. Consider to use managed instance group with load balancer which currently do not have.
  tags         = ["newsfeed"]

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-125-lts"
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.subnet.self_link

    access_config {
      // Ephemeral IP
    }
  }

  metadata_startup_script = templatefile("${path.module}/provision-newsfeed.sh", {
    docker_image = "${local.gcr_url}/newsfeed:latest"
  })

  service_account {
    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    email  = google_service_account.joi-news-instances.email
    scopes = var.service_account_scopes
  }
}

resource "google_compute_firewall" "newsfeed" {
  name    = "newsfeed-firewall"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["8081"]
  }

  source_ranges = ["10.10.0.0/16"]                                                         ### Consider to change to 10.5.0.0/16, private IP addressing
  target_tags   = ["newsfeed"]
}

#output "frontend_url" {
 # value = "http://${google_compute_instance.front_end.network_interface.0.access_config.0.nat_ip}:80"
#}



###############################################################################
### NEW: EXTERNAL APPLICATION LOAD BALANCER CONFIGURATION
###############################################################################

# 1. Map the single standalone front-end instance into an Unmanaged Instance Group
resource "google_compute_instance_group" "frontend_group" {
  name        = "${var.prefix}-frontend-ig"
  description = "Unmanaged instance group for the frontend server"
  zone        = "${var.region}-a"

  instances = [
    google_compute_instance.front_end.self_link
  ]

  named_port {
    name = "http"
    port = 80
  }
}

# 2. Reserve a dedicated global public IP address for your users
resource "google_compute_global_address" "lb_static_ip" {
  name = "${var.prefix}-lb-static-ip"
}

# 3. Global Forwarding Rule (The frontend configuration of the load balancer)
resource "google_compute_global_forwarding_rule" "http_forwarding_rule" {
  name                  = "${var.prefix}-forwarding-rule"
  ip_address            = google_compute_global_address.lb_static_ip.address
  ip_protocol           = "TCP"
  port_range            = "80"
  target                = google_compute_target_http_proxy.http_proxy.self_link
  load_balancing_scheme = "EXTERNAL"
}

# 4. Target HTTP Proxy
resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "${var.prefix}-http-proxy"
  url_map = google_compute_url_map.url_map.self_link
}

# 5. URL Map (Handles Layer 7 routing directions)
resource "google_compute_url_map" "url_map" {
  name            = "${var.prefix}-url-map"
  default_service = google_compute_backend_service.frontend_backend.self_link
}

# 6. Backend Service definition linking the Load Balancer to the Instance Group
resource "google_compute_backend_service" "frontend_backend" {
  name                  = "${var.prefix}-backend-service"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL"
  timeout_sec           = 30

  backend {
    group = google_compute_instance_group.frontend_group.self_link
  }

  health_checks = [google_compute_health_check.lb_health_check.self_link]
}

# 7. Health Check config to verify the frontend instance is still running
resource "google_compute_health_check" "lb_health_check" {
  name               = "${var.prefix}-lb-health-check"
  timeout_sec        = 5
  check_interval_sec = 10

  http_health_check {
    port = 80
    # Update request_path if your container uses a specific endpoint like /healthz
    request_path = "/" 
  }
}

###############################################################################
### OUTPUTS UPDATE
###############################################################################

# Updated output to provide the static, load-balanced entry point
output "frontend_url" {
  value = "http://${google_compute_global_address.lb_static_ip.address}"
}
