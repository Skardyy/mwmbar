class Mwmbar < Formula
  desc "Aerospace workspace pills bar for macOS"
  homepage "https://github.com/Skardyy/mwmbar"
  url "https://github.com/Skardyy/mwmbar/archive/refs/tags/0.6.2.tar.gz"
  sha256 "b1b3cec9d98162a4555fc96a4872ffd6fe65c3464578c2d699780fbe91f98240"
  head "https://github.com/Skardyy/mwmbar.git", branch: "master"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/mwmbar"
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
