class AiTrash < Formula
  desc "Transparent rm/rmdir replacement that routes files to a recoverable trash"
  homepage "https://github.com/forethought-studio/ai-trash"
  url "https://github.com/forethought-studio/ai-trash/archive/refs/tags/v1.6.13.tar.gz"
  sha256 "9e939f7e2f9ebde56196de4265043428fd03f3cefdb6518753b2d5c13a84261a"
  license "MIT"

  # macOS only — relies on xattr, launchctl, and macOS Trash conventions
  depends_on :macos

  def install
    bin.install "ai-trash-lib.sh"
    bin.install "rm_wrapper.sh"
    bin.install "git_wrapper.sh"
    bin.install "find_wrapper.sh"
    bin.install "rsync_wrapper.sh"
    bin.install "ai-trash-cleanup"
    bin.install "ai-trash"

    # Intercept commands by symlinking into Homebrew's bin, which should
    # appear before /bin in PATH after `brew shellenv` is sourced.
    bin.install_symlink "rm_wrapper.sh" => "rm"
    bin.install_symlink "rm_wrapper.sh" => "rmdir"
    bin.install_symlink "rm_wrapper.sh" => "unlink"
    bin.install_symlink "git_wrapper.sh" => "git"
    bin.install_symlink "find_wrapper.sh" => "find"
    bin.install_symlink "rsync_wrapper.sh" => "rsync"
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
      ai-trash intercepts protected commands by placing wrappers earlier in PATH.
      Make sure Homebrew's bin comes before /bin in your PATH:

        export PATH="#{HOMEBREW_PREFIX}/bin:$PATH"

      After installing, enable the cleanup service (purges items >30 days old):

        brew services start ai-trash

      To verify the override is active:

        which rm   # should show #{opt_bin}/rm
        which rsync # should show #{opt_bin}/rsync
    EOS
  end

  test do
    assert_match "ai-trash 1.6.13", shell_output("#{bin}/ai-trash version")
  end
end
