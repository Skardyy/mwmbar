class Mwmbar < Formula
  desc "Aerospace workspace pills bar for macOS"
  homepage "https://github.com/Skardyy/mwmbar"
  url "https://github.com/Skardyy/mwmbar/archive/refs/tags/0.1.1.tar.gz"
  sha256 "1503df60710361f4516c9b9084a593963b144b8941c98a061d348fb4b55d96b2"
  head "https://github.com/Skardyy/mwmbar.git", branch: "master"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"

    app = prefix/"Mwmbar.app"
    (app/"Contents/MacOS").install ".build/release/mwmbar"
    (app/"Contents").install "Resources/Info.plist"

    # ad-hoc sign the bundle with a stable identifier so TCC can anchor
    # Accessibility / Screen Recording grants to it. without an explicit
    # identifier the cdhash is used and every upgrade silently revokes.
    system "/usr/bin/codesign", "--force", "--deep", "--sign", "-",
           "--identifier", "com.skardyy.mwmbar",
           app.to_s

    bin.write_exec_script app/"Contents/MacOS/mwmbar"
  end

  service do
    run opt_prefix/"Mwmbar.app/Contents/MacOS/mwmbar"
    keep_alive true
    log_path var/"log/mwmbar.log"
    error_log_path var/"log/mwmbar.log"
  end

  test do
    assert_predicate prefix/"Mwmbar.app/Contents/MacOS/mwmbar", :exist?
  end
end
