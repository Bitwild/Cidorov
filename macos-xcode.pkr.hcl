packer {
  required_plugins {
    tart = {
      version = ">= 1.14.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "macos_version" {
  type = string
}
variable "xcode_version" {
  type = string
}
variable "github_runner_org" {
  type = string
  default = env("GITHUB_RUNNER_ORG")
}
variable "github_runner_token" {
  type = string
  default = env("GITHUB_RUNNER_TOKEN")
}

source "tart-cli" "tart" {
  vm_base_name = "ghcr.io/cirruslabs/macos-${var.macos_version}-xcode:${var.xcode_version}"
  vm_name      = "macos-${var.macos_version}-xcode:${var.xcode_version}"
  cpu_count    = 8
  memory_gb    = 12
  headless     = true
  ssh_username = "admin"
  ssh_password = "admin"
  ssh_timeout = "30s"
  # https://github.com/cirruslabs/packer-plugin-tart/issues/79
  run_extra_args = [
    "--net-bridged=en0",
    "--dir=cache:~/.tartly/cache",
  ]
  ip_extra_args = ["--resolver=arp"]
  display      = "1920x1200"
}

build {
  sources = ["source.tart-cli.tart"]

  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "brew --version",

      # Update and upgrade packages.
      "brew update",
      "brew upgrade",

      # Install additional tooling.
      "brew install create-dmg",
    ]
  }

  provisioner "shell" {
    inline = [
      # Need to be in the "root" folder for this shit to work…
      "cd ~/actions-runner",

      # Update the runner's .path and .env – it doesn't load profile.
      "source ~/.zprofile",
      "echo $PATH > .path",
      "./env.sh",
      "echo 'RUNNER_TOOL_CACHE=/Volumes/My Shared Files/cache' >> .env",

      # Register the runner and install a launchd service for auto-starts.
      "./config.sh --unattended --replace --url https://github.com/${var.github_runner_org} --token ${var.github_runner_token} --name macos-${var.macos_version}-xcode-${var.xcode_version} --labels macos,xcode-${var.xcode_version},${var.macos_version}",
      "./svc.sh install",
      "./svc.sh start",
    ]
  }
}
