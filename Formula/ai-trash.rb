class AiTrash < Formula
  desc "Transparent rm/rmdir replacement that routes files to a recoverable trash"
  homepage "https://github.com/forethought-studio/ai-trash"
  url "https://github.com/forethought-studio/ai-trash/archive/refs/tags/v1.6.11.tar.gz"
  sha256 "5ce35889e60960b45c7664fec14d601b6b2d5442ba477dd2597926f2edba660f"
  license "MIT"

  # macOS only — relies on xattr, launchctl, and macOS Trash conventions
  depends_on :macos

  def install
    bin.install "rm_wrapper.sh"
    bin.install "ai-trash-cleanup"
    bin.install "ai-trash"

    # Intercept rm and rmdir by symlinking into Homebrew's bin, which should
    # appear before /bin in PATH after `brew shellenv` is sourced.
    bin.install_symlink "rm_wrapper.sh" => "rm"
    bin.install_symlink "rm_wrapper.sh" => "rmdir"
  end

  service do
    run [opt_bin/"ai-trash-cleanup"]
    run_type :interval
    interval 21600  # every 6 hours
    log_path var/"log/ai-trash-cleanup.log"
    error_log_path var/"log/ai-trash-cleanup.log"
  end

  def caveats
    <<~EOS
      ai-trash intercepts `rm` and `rmdir` by placing wrappers earlier in PATH.
      Make sure Homebrew's bin comes before /bin in your PATH:

        export PATH="#{HOMEBREW_PREFIX}/bin:$PATH"

      After installing, enable the cleanup service (purges items >30 days old):

        brew services start ai-trash

      To verify the override is active:

        which rm   # should show #{opt_bin}/rm
    EOS
  end

  test do
    assert_match "ai-trash 1.6.11", shell_output("#{bin}/ai-trash version")
  end
end
