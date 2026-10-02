class Mwmbar < Formula
  desc "Aerospace workspace pills bar for macOS"
  homepage "https://github.com/Skardyy/mwmbar"
  url "https://github.com/Skardyy/mwmbar/archive/refs/tags/0.1.2.tar.gz"
  sha256 "0a581a54077cd3368ff410feb3e9ecd88243b0d1fb737cc820af5bd723292fa7"
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
