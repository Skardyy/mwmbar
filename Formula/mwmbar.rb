class Mwmbar < Formula
  desc "Aerospace workspace pills bar for macOS"
  homepage "https://github.com/Skardyy/mwmbar"
  url "https://github.com/Skardyy/mwmbar/archive/refs/tags/0.13.0.tar.gz"
  sha256 "cf76032b8ec471b544ab0497b0cc4954d517b251a60f4abc9c496b4c60439247"
  head "https://github.com/Skardyy/mwmbar.git", branch: "master"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/mwmbar"
    # Bundle.module (used to load the bundled oui vendor lookup table)
    # fatal-errors at runtime if this resource bundle is not sitting next
    # to the executable, so it has to be installed alongside it too.
    bin.install ".build/release/mwmbar_mwmbar.bundle"
    system "/usr/bin/codesign", "--force", "-s", "-",
           "--identifier", "com.skardyy.mwmbar",
           bin/"mwmbar"
  end

  service do
    run opt_bin/"mwmbar"
    keep_alive true
    log_path var/"log/mwmbar.log"
    error_log_path var/"log/mwmbar.log"
  end

  test do
    assert_predicate bin/"mwmbar", :exist?
  end
end
