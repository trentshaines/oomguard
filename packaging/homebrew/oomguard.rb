# Formula for a tap (github.com/trentshaines/homebrew-tap). Fill in url/sha256 per release:
#   shasum -a 256 oomguard-<version>.tar.gz
class Oomguard < Formula
  desc "Early OOM killer for macOS: kills the biggest job before memory pressure crashes the Mac"
  homepage "https://github.com/trentshaines/oomguard"
  url "https://github.com/trentshaines/oomguard/archive/refs/tags/v0.2.1.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
  license "MIT"

  # Builds with the Swift 6 in Xcode or the Command Line Tools.
  depends_on macos: :ventura

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/oomguard"
    pkgshare.install "config.example.toml"
  end

  service do
    run [opt_bin/"oomguard", "run"]
    keep_alive true
    process_type :interactive
    log_path var/"log/oomguard.log"
    error_log_path var/"log/oomguard.log"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/oomguard version")
    assert_match "pressure:", shell_output("#{bin}/oomguard status")
  end
end
