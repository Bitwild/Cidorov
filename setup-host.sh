#!/bin/bash
set -euo pipefail

# Disable system sleep on all power sources.
sudo pmset -a sleep 0
sudo pmset -a disablesleep 1
sudo pmset -a displaysleep 0

# Auto-start after power loss.
sudo pmset -a autorestart 1
sudo nvram AutoBoot=%03

# Disable system and display sleep on AC (VNC / remote-friendly).
PM_PLIST=$(ls /Library/Preferences/com.apple.PowerManagement.*.plist | head -n 1)
sudo defaults write "$PM_PLIST" "AC Power" -dict-add "System Sleep Timer" 0
sudo defaults write "$PM_PLIST" "AC Power" -dict-add "Display Sleep Timer" 0

# Extra belt-and-braces: match GUI "Computer sleep: Never".
sudo systemsetup -setcomputersleep Never

# Disable screensaver for this user.
defaults -currentHost write com.apple.screensaver idleTime -int 0

# Reduce DHCP lease time to 2 hours.
sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.InternetSharing.default.plist bootpd -dict DHCPLeaseTimeSecs -int 7200

# Enable SSH for remote login (optional but useful).
sudo systemsetup -setremotelogin on

# Activate Remote Management and allow only the current user with full privileges.
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate \
  -configure \
  -access -on \
  -users "$(id -un)" \
  -privs -all \
  -restart -agent \
  -menu

# Install Homebrew if missing.
if ! command -v brew >/dev/null 2>&1; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install dependencies.
brew install \
  gh \
  cirruslabs/cli/tart \
  hashicorp/tap/packer
