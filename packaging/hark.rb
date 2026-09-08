# Homebrew cask for Hark.
#
# Lives here as the source of truth. scripts/release.sh stamps the version,
# url and sha256 after a release; copy the file into the tap repo
# (tjameswilliams/homebrew-tap -> Casks/hark.rb), which is what
# `brew install --cask tjameswilliams/tap/hark` reads.
#
# Hark does not embed an in-app updater, so there is no `auto_updates`:
# `brew upgrade` is the update path, which is why the cask pins a versioned
# dmg (Hark-<version>.dmg) rather than the evergreen /downloads/Hark.dmg the
# website links. deploy.sh uploads versioned dmgs without --delete, so every
# pinned URL keeps resolving after later releases.
cask "hark" do
  version "0.2.0"
  sha256 "21cf3ce5bdb16001850140774c79f072db649031ae13c83fd899f3f01ddc620d"

  url "https://harkdictate.com/downloads/Hark-#{version}.dmg"
  name "Hark"
  desc "Local push-to-talk dictation and meeting transcription"
  homepage "https://harkdictate.com/"

  # release.sh writes downloads/latest-version.txt next to the dmgs and
  # deploy.sh uploads it, so `brew audit --online` can check the stamped
  # version against what the site serves.
  livecheck do
    url "https://harkdictate.com/downloads/latest-version.txt"
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  # Core ML inference on the Neural Engine and Core Audio process taps: Apple
  # Silicon and macOS 15 are hard floors, not preferences.
  depends_on macos: :sequoia
  depends_on arch: :arm64

  app "Hark.app"
  # The MCP server ships inside the bundle (the app locates it relative to its
  # own executable); linking it onto PATH is what makes
  # `hark-mcp install --client ...` work from a terminal.
  binary "#{appdir}/Hark.app/Contents/MacOS/hark-mcp"

  zap trash: [
    "~/Library/Application Support/Hark",
    "~/Library/Logs/Hark",
    "~/Library/Preferences/com.hark.app.plist",
  ]
end
