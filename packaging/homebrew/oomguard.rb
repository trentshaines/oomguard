# Copy of Formula/oomguard.rb in github.com/trentshaines/homebrew-tap. Per release: update the
# url, then sha256 from `curl -sL <url> | shasum -a 256`.
class Oomguard < Formula
  desc "Early OOM killer for macOS: kills the biggest job before memory runs out"
  homepage "https://github.com/trentshaines/oomguard"
  url "https://github.com/trentshaines/oomguard/archive/refs/tags/v0.2.1.tar.gz"
  sha256 "80b3db0d51724e5b48dad77fbf8e73c70376c4707c6a64cd9369ad4d90752063"
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
