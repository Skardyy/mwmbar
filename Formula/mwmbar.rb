class Mwmbar < Formula
  desc "Aerospace workspace pills bar for macOS"
  homepage "https://github.com/Skardyy/mwmbar"
  url "https://github.com/Skardyy/mwmbar/archive/refs/tags/0.1.2.tar.gz"
  sha256 "0a581a54077cd3368ff410feb3e9ecd88243b0d1fb737cc820af5bd723292fa7"
  head "https://github.com/Skardyy/mwmbar.git", branch: "master"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/mwmbar"
    # TCC uses the code signature to key Accessibility and Screen
    # Recording grants; without one, every upgrade produces a different
    # binary identity and the user has to re grant from scratch.
    system "/usr/bin/codesign", "--force", "-s", "-", bin/"mwmbar"
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
