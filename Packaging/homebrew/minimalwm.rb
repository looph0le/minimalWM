cask "minimalwm" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/looph0le/minimalWM/releases/download/v#{version}/minimalWM-universal.zip"
  name "minimalWM"
  desc "Native master-stack tiling window manager for macOS"
  homepage "https://github.com/looph0le/minimalWM"

  app "minimalWM.app"

  zap trash: [
    "~/.config/minimalWM",
    "~/Library/LaunchAgents/com.minimalWM.plist",
  ]
end
