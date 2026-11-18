# Homebrew formula for dicomtool - DICOM file inspection and conversion CLI
class Dicomtool < Formula
  desc "Command-line tool for DICOM file inspection, validation, and conversion"
  homepage "https://github.com/ThalesMMS/DICOM-Swift"
  url "https://github.com/ThalesMMS/DICOM-Swift/archive/refs/tags/1.0.1.tar.gz"
  # To obtain SHA256, run: curl -sL "https://github.com/ThalesMMS/DICOM-Swift/archive/refs/tags/1.0.1.tar.gz" | shasum -a 256
  sha256 "d5480b7608ef33b79d8c45110b8a6316e9f78ebe40e6977da7a3ddebad38d114"
  license "Apache-2.0"
  head "https://github.com/ThalesMMS/DICOM-Swift.git", branch: "main"

  depends_on xcode: ["14.0", :build]
  depends_on :macos

  def install
    # Build the release binary using Swift Package Manager
    system "swift", "build", "-c", "release", "--disable-sandbox"

    # Install the binary to Homebrew's bin directory
    bin.install ".build/release/dicomtool"
  end

  test do
    # Test that the binary runs and shows help
    assert_match "OVERVIEW: DICOM file inspection and conversion tool", shell_output("#{bin}/dicomtool --help")

    # Test version information
    assert_match "dicomtool", shell_output("#{bin}/dicomtool --version 2>&1", 0)
  end

  def caveats
    <<~EOS
      dicomtool has been installed!

      Usage examples:
        # Inspect DICOM metadata
        dicomtool inspect file.dcm

        # Validate DICOM conformance
        dicomtool validate file.dcm

        # Extract pixel data to PNG
        dicomtool extract file.dcm --output image.png --preset lung

        # Batch process directory
        dicomtool batch inspect --pattern "*.dcm" /path/to/directory

      For full documentation, visit:
      https://github.com/ThalesMMS/DICOM-Swift
    EOS
  end
end
