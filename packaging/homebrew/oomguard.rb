# Copy of Formula/oomguard.rb in github.com/trentshaines/homebrew-tap. Per release: update the
# url, then sha256 from `curl -sL <url> | shasum -a 256`.
class Oomguard < Formula
  desc "Early OOM killer for macOS: kills the biggest job before memory runs out"
  homepage "https://github.com/trentshaines/oomguard"
  url "https://github.com/trentshaines/oomguard/archive/refs/tags/v0.2.1.tar.gz"
  sha256 "c04b3c80a2578ad45d6be6c2eae7357449f0317c65fb8e9a36e6ba942c533582"
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
