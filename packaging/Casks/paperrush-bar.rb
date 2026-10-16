cask "paperrush-bar" do
  version "1.2.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/LucasHyun/paperrush-bar/releases/download/v#{version}/PaperRushBar-v#{version}.zip"
  name "PaperRush Bar"
  desc "Menu bar countdown to the next AI conference deadline"
  homepage "https://github.com/LucasHyun/paperrush-bar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "PaperRushBar.app"

  # The build is ad-hoc signed, not notarized. A freshly downloaded copy is quarantined,
  # and its first launch then offers "Move to Trash" -- one click that deletes the app
  # brew just installed, which is how it kept vanishing from /Applications. The tap is
  # this project's own, so it clears the quarantine on its own app instead.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/PaperRushBar.app"]
  end

  uninstall quit: "com.lucashyun.paperrushbar"

  zap trash: [
    "~/Library/Application Support/PaperRushBar",
    "~/Library/Preferences/com.lucashyun.paperrushbar.plist",
  ]
end
