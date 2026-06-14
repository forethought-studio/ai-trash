class AiTrash < Formula
  desc "Transparent rm/rmdir replacement that routes files to a recoverable trash"
  homepage "https://github.com/forethought-studio/ai-trash"
  url "https://github.com/forethought-studio/ai-trash/archive/refs/tags/v1.6.19.tar.gz"
  sha256 "222bb1c9f4a88562c16cddc016c4b9a2f21c66d308e0b206f7a47542086bbdec"
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

    # Duplicate-wrapper safety: the scanner detects another command wrapper
    # shadowing ours on PATH (which can re-introduce the wrapper-recursion
    # spin), and the banner is the shell-rc hook that surfaces its warnings.
    bin.install "scripts/check-path-shadows.sh"
    bin.install "scripts/ai-trash-banner.sh"

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
    interval 21600 # every 6 hours
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

      A duplicate-wrapper scanner is installed but not auto-scheduled (brew
      formulae allow only one service, used here by the cleanup job). Run it
      on demand, and source the banner from your shell rc for sticky warnings:

        #{opt_bin}/check-path-shadows.sh
        echo 'source #{opt_bin}/ai-trash-banner.sh' >> ~/.zshrc

      For the daily auto-scan LaunchAgent, use the repo's install.sh instead.
    EOS
  end

  test do
    assert_match(/^ai-trash \d+\.\d+\.\d+$/, shell_output("#{bin}/ai-trash version"))
  end
end
