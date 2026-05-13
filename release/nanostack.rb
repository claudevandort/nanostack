# Homebrew formula template.
#
# The release workflow substitutes {{VERSION}}, the four {{SHA256_*}} values,
# and {{URL_BASE}} for each tagged release, then opens a PR against
# claudevandort/homebrew-nanostack with the rendered formula.

class Nanostack < Formula
  desc "Snappy, accurate AWS S3 emulator for local development"
  homepage "https://github.com/claudevandort/nanostack"
  version "{{VERSION}}"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "{{URL_BASE}}/nanostack-v{{VERSION}}-macos-aarch64.tar.gz"
      sha256 "{{SHA256_MACOS_AARCH64}}"
    end
    on_intel do
      url "{{URL_BASE}}/nanostack-v{{VERSION}}-macos-x86_64.tar.gz"
      sha256 "{{SHA256_MACOS_X86_64}}"
    end
  end

  on_linux do
    on_arm do
      url "{{URL_BASE}}/nanostack-v{{VERSION}}-linux-aarch64.tar.gz"
      sha256 "{{SHA256_LINUX_AARCH64}}"
    end
    on_intel do
      url "{{URL_BASE}}/nanostack-v{{VERSION}}-linux-x86_64.tar.gz"
      sha256 "{{SHA256_LINUX_X86_64}}"
    end
  end

  def install
    bin.install "nanostack"
  end

  test do
    assert_match "nanostack v#{version}", shell_output("#{bin}/nanostack --version").strip
  end
end
