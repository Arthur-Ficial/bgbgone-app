#!/bin/zsh
# render-homebrew-cask.sh <version> <sha256> — emit Casks/bgbgone-app.rb to stdout.
set -euo pipefail

VERSION="${1:?version required}"
SHA="${2:?sha256 required}"

cat <<RUBY
cask "bgbgone-app" do
  version "${VERSION}"
  sha256 "${SHA}"

  url "https://github.com/Arthur-Ficial/bgbgone-app/releases/download/v#{version}/bgbgone-app-v#{version}-macos-arm64.zip"
  name "bgbgone"
  desc "macOS GUI for the bgbgone background removal CLI (Apple Vision, on-device, batchable)"
  homepage "https://github.com/Arthur-Ficial/bgbgone-app"

  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "bgbgone-app.app"

  zap trash: [
    "~/Library/Application Support/bgbgone-app",
    "~/Library/Preferences/com.fullstackoptimization.bgbgone-app.plist",
    "~/Library/Caches/com.fullstackoptimization.bgbgone-app",
  ]
end
RUBY
