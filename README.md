# Tartly

Dead-simple management for self-hosted GitHub Actions macOS runners powered by [Tart](https://github.com/cirruslabs/tart) and inspired by [macOS Packer Templates for Tart](https://github.com/cirruslabs/macos-image-templates). Their GitHub projects are the best place to understand how to customize, build, and publish macOS images specifically for self-hosted runners:

- [All published images](https://github.com/orgs/cirruslabs/packages?repo_name=macos-image-templates).
- [Sequoia vanilla image script](https://github.com/cirruslabs/macos-image-templates/blob/master/templates/vanilla-sequoia.pkr.hcl).
- [Base image source (without Xcode)](https://github.com/cirruslabs/macos-image-templates/blob/master/templates/base.pkr.hcl)
- [Runner image source (with Xcode)](https://github.com/cirruslabs/macos-image-templates/blob/master/templates/xcode.pkr.hcl)
- [CI script for building packer images](https://github.com/cirruslabs/macos-image-templates/blob/master/.ci/cirrus.xcode.yml).


## 💡 Usage

There are 3 main CLI scripts that do all the work:

- `setup-host.sh`: Configure clean macOS machine for self-hosted runners – **make sure to do this first**, see [macOS setup](#🍎-macos-setup) below.
- `setup-vm.sh`: Create customized macOS Tart VM based on official [Cirrus CI (Tart) macOS Xcode templates](https://github.com/cirruslabs/macos-image-templates).
- `svc.sh`: Set up Tart VM as a service and manage autostart on system boot.


### CI host setup

> [!TIP]
> If setting up a clean macOS machine, you can Use [Mist](https://github.com/ninxsoft/Mist) to create a bootable flash drive – plug it in and restart in recovery mode:
> - On a Mac mini: after shut down, long-press the power until the boot menu appears.
> - On a MacBook Pro: keep pressing the option key until the boot menu appears.

Clone the repo and run the setup script:
```sh
mkdir ~/Development
cd ~/Development

# Clone the remote or force-reset to the latest version:
git clone https://github.com/Bitwild/Tartly.git Tartly
git fetch origin && git reset --hard origin/main

# Run the setup script.
Tartly/setup-host.sh
```

See [Tartlet's Setting Up a Host Machine](https://github.com/shapehq/tartelet/wiki/Setting-Up-a-Host-Machine) guide for extra details and tips.

### CI runner setup

```sh
# Create a macOS image with Xcode 16.1.
./setup-vm.sh --macos sonoma --xcode 16.1 --org Bitwild 

# Install the service to autostart on system boot.
./svc.sh install macos-sonoma-xcode:16.1

# Start or stop the service.
./svc.sh stop macos-sonoma-xcode:16.1
./svc.sh start macos-sonoma-xcode:16.1

# Uninstall the service.
./svc.sh uninstall macos-sonoma-xcode:16.1

# List all Tart vms.
tart list

# SSH into the VM.
ssh admin@$(tart ip macos-sonoma-xcode:16.1)
```


# 📜 Scripts
```sh

# Use concurrency to speed up the pulling.
tart pull --concurrency 8 ghcr.io/cirruslabs/macos-sonoma-xcode:16.1

# Initialize the Packer template.
packer init -upgrade macos-xcode.pkr.hcl

# Build a custom image and register the runner.
packer build \
  -var "macos_version=sonoma" \
  -var "xcode_version=16.1" \
  -var "github_runner_org=Bitwild" \
  -var "github_runner_token=$(gh api --method POST orgs/Bitwild/actions/runners/registration-token --jq .token)" \
  macos-xcode.pkr.hcl

# Install launch agent for the current user.
mkdir -p ~/Library/LaunchAgents
cp launchd.plist ~/Library/LaunchAgents/co.bitwild.cidorov.tart.plist

# Load and start the agent (runs Tart and keeps the VM alive).
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.bitwild.cidorov.tart.plist

# Stop the agent but keep it registered.
launchctl stop co.bitwild.cidorov.tart

# Start it again without reloading the plist.
launchctl start co.bitwild.cidorov.tart

# Unload the agent completely (stop and unregister).
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/co.bitwild.cidorov.tart.plist

# Check status if you suspect it is stuck or dead.
launchctl print gui/$(id -u)/co.bitwild.cidorov.tart
```

## 🥧 Tart commands

```sh
# Run the VM in the background.
tart run --no-graphics macos-sonoma-xcode:16.1 &
```

## 🥧 Tartly vs. Tart, Tartlet, Orchard

There are several approaches for dealing with self-hosted CI runners. All involve using [Tart](https://github.com/cirruslabs/tart) and their [macOS Xcode images](https://github.com/orgs/cirruslabs/packages?repo_name=macos-image-templates) from [macos-image-templates](https://github.com/cirruslabs/macos-image-templates) repo:

1. **[Tart](https://github.com/cirruslabs/tart):** Simplest, but no handling for host restarts or guest failures. Tart is the base layer for all other tools, including Tartly.

2. **[Tartlet](https://github.com/shapehq/tartelet):** A really neat and simple app, but relies on ephemeral (not persistent) VMs – this might be good, but adds more overhead and complexity (startups, warmups, cache, etc.) Currently, there's no headless operation support and limited runner configuration.

3. **[Orchard](https://github.com/cirruslabs/orchard):** An official tool for running Tart VMs, supports VM persistency and restart handling, however, I couldn't find the actual auto-start support for workers. There's no friction-free way of setting up a VM either, like no way to pass environment variables, which is more of a macOS Virtualization limitation. Overall, Orchard is an overkill for a single host runner…

In an ideal world, we'd build a Tart VM image, push it to GitHub Packages, and use Tartlet or Orchard to run it. Unfortunately, pushing and pulling images takes eternity, unless using a local registry.

Tartly uses a simpler approach:
1. Pull the standard VM image locally.
2. Customize it with Packer (takes just a minute or two).
3. Run it with a custom launch agent with auto-start support.
