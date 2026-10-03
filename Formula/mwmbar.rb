class Mwmbar < Formula
  desc "Aerospace workspace pills bar for macOS"
  homepage "https://github.com/Skardyy/mwmbar"
  url "https://github.com/Skardyy/mwmbar/archive/refs/tags/0.3.0.tar.gz"
  sha256 "0771de6d078ae475e6bfe446ec1f9d7fc7d0443c113c9a1792dd987f93efa597"
  head "https://github.com/Skardyy/mwmbar.git", branch: "master"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/mwmbar"
    # pin the designated requirement to the bundle identifier so TCC
    # keys the Accessibility and Screen Recording grants to a stable
    # string instead of the per build cdhash. without this the user
    # must re grant every upgrade.
    system "/usr/bin/codesign", "--force", "-s", "-",
           "--identifier", "com.skardyy.mwmbar",
           "-r", "=designated => identifier \"com.skardyy.mwmbar\"",
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
