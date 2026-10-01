# DicomSwiftUI Example Application

A complete reference implementation demonstrating all SwiftUI components in the DicomSwiftUI library for building DICOM medical image viewing applications.

## Overview

This example app showcases the four main SwiftUI components provided by the DicomSwiftUI library:

- **DicomImageView** - Display DICOM images with automatic scaling and windowing
- **WindowingControlView** - Interactive window/level adjustment controls
- **SeriesNavigatorView** - Navigate through multi-slice DICOM series
- **MetadataView** - Display formatted DICOM metadata tags

## Platform Requirements

- **iOS / visionOS / macOS**: 26.0 or later
- **Swift toolchain**: 6.2 or later
- **DICOM-Swift language mode**: Swift 6

## Running the Example App

### Option 1: Using Swift Package Manager (Recommended)

From the repository root directory:

```bash
# Build and run the example app
swift run DicomSwiftUIExample
```

### Option 2: Using Xcode

1. Open `Package.swift` in Xcode
2. Select the `DicomSwiftUIExample` scheme from the scheme selector
3. Choose your target device/simulator
4. Press `⌘R` to build and run

## TestFlight Beta Access

### Joining the TestFlight Beta

The easiest way to evaluate the DicomSwiftUI library is through TestFlight, Apple's beta testing platform. This allows you to try the full-featured example app on your iOS device without setting up a development environment.

#### Prerequisites

- **iOS Device**: iPhone or iPad running iOS 26.0 or later
- **TestFlight App**: Download from the [App Store](https://apps.apple.com/app/testflight/id899247664) (free)
- **Apple ID**: Required to join the beta program

#### How to Join

1. **Install TestFlight** from the App Store on your iOS device
2. **Request Access**: Contact the repository maintainers via [GitHub Issues](https://github.com/ThalesMMS/DICOM-Swift/issues) to request a TestFlight invitation
3. **Accept Invitation**: You'll receive an email or public link to join the beta
4. **Install the App**: Open the invitation link on your iOS device to install via TestFlight
5. **Start Testing**: Launch the app and begin exploring DICOM image viewing features

#### What to Test

Once installed, try these key features:

- **File Import**: Import DICOM files from Files app, iCloud Drive, or network shares
- **Study Browser**: Browse imported studies with patient information
- **Series Navigation**: Navigate through multi-slice CT/MR series
- **Interactive Viewing**: Test gesture controls (pinch-to-zoom, pan, windowing)
- **Medical Presets**: Apply lung, bone, brain, and other clinical presets
- **Performance**: Evaluate loading speed and GPU-accelerated windowing

#### Providing Feedback

TestFlight allows you to send feedback directly:

- **In-App Feedback**: Shake your device while using the app → "Send Beta Feedback"
- **Screenshot Feedback**: Take a screenshot → annotate → send via TestFlight
- **GitHub Issues**: Report bugs or request features at [GitHub Issues](https://github.com/ThalesMMS/DICOM-Swift/issues)

### Publishing Your Own TestFlight Build

If you've customized the example app or built your own DICOM viewer, you can distribute it via TestFlight to your team or users.

#### Prerequisites

- **Apple Developer Account**: [$99/year individual or organization account](https://developer.apple.com/programs/)
- **Xcode**: 26.0 or later
- **Device**: Mac running macOS 26.0 or later
- **App Store Connect Access**: Admin or App Manager role

#### Step 1: Configure Xcode Project

1. **Open Project in Xcode**:
   ```bash
   cd Examples/DicomSwiftUIExample
   open Package.swift
   ```

2. **Select Target**: Choose `DicomSwiftUIExample` from the scheme selector

3. **Configure Signing**:
   - Select the `DicomSwiftUIExample` target in the project navigator
   - Go to "Signing & Capabilities" tab
   - Check "Automatically manage signing"
   - Select your development team from the dropdown
   - Xcode will create/update the Bundle Identifier (e.g., `com.yourteam.DicomSwiftUIExample`)

4. **Update Info.plist**:
   - Open `Examples/DicomSwiftUIExample/Info.plist`
   - Update `CFBundleDisplayName` to your app name
   - Update `CFBundleIdentifier` if needed (must match Xcode signing settings)
   - Ensure `CFBundleShortVersionString` follows semantic versioning (e.g., "1.0.0")
   - Set `CFBundleVersion` build number (increment for each build, e.g., "1", "2", "3")

#### Step 2: Create App Store Connect Record

1. **Log in to App Store Connect**: [https://appstoreconnect.apple.com](https://appstoreconnect.apple.com)

2. **Create App**:
   - Go to "My Apps" → Click "+" → "New App"
   - **Platform**: iOS
   - **Name**: Your app name (user-facing, can differ from Bundle Display Name)
   - **Primary Language**: English (or your preference)
   - **Bundle ID**: Select the Bundle ID Xcode created (e.g., `com.yourteam.DicomSwiftUIExample`)
   - **SKU**: Unique identifier (e.g., `dicom-swiftui-example-001`)
   - **User Access**: Full Access

3. **Configure App Information** (required before first upload):
   - **Privacy Policy URL**: Required (even for beta-only apps)
   - **Category**: Medical or Developer Tools
   - **App Icon**: Upload 1024×1024 PNG (generated from Assets.xcassets)

#### Step 3: Archive and Upload

1. **Select Device Destination**:
   - In Xcode, select "Any iOS Device (arm64)" from the destination menu
   - Do NOT use a simulator destination (archives require real device architecture)

2. **Archive the App**:
   - Menu: **Product** → **Archive**
   - Xcode builds and creates an archive (5-10 minutes depending on Mac speed)
   - The Organizer window opens automatically when complete

3. **Validate Archive** (optional but recommended):
   - Select the archive in Organizer
   - Click **Validate App**
   - Choose your distribution certificate and provisioning profile
   - Review validation results (fix any errors before uploading)

4. **Distribute to App Store Connect**:
   - Click **Distribute App**
   - Select **App Store Connect** → Next
   - Select **Upload** → Next
   - **Distribution Options**:
     - ☑ Upload your app's symbols (recommended for crash reports)
     - ☑ Manage Version and Build Number (Xcode auto-increments)
   - Click **Upload**
   - Wait for upload to complete (5-20 minutes depending on app size and internet speed)

#### Step 4: Configure TestFlight

1. **Wait for Processing**:
   - After upload, Apple processes the build (30 minutes to 2 hours)
   - You'll receive an email when processing completes
   - Refresh App Store Connect to see the build appear under "TestFlight" tab

2. **Add Beta Information**:
   - Go to **TestFlight** → **iOS Builds** → Select your build
   - **What to Test**: Describe new features or changes (e.g., "Interactive DICOM viewing with gesture controls")
   - **Test Details**: Provide testing instructions and sample file locations
   - **Privacy Policy**: Required if collecting user data

3. **Compliance Questions**:
   - **Export Compliance**: Answer "No" for medical imaging viewers (no encryption beyond standard HTTPS)
   - If you use encryption, you may need to submit compliance documentation

4. **Submit for Beta Review** (first build only):
   - Click **Submit for Review**
   - Apple reviews for TestFlight (usually 24-48 hours)
   - You'll receive email when approved

#### Step 5: Invite Testers

**Internal Testing** (up to 100 Apple Developer Program members):

1. **Add Internal Testers**:
   - Go to **TestFlight** → **Internal Testing** → **Internal Group**
   - Click "+" to add testers by email
   - Testers must be added to your App Store Connect team first

2. **Enable Builds**:
   - Check the builds you want to make available
   - Testers receive email invitations automatically

**External Testing** (up to 10,000 external users):

1. **Create External Group**:
   - Go to **TestFlight** → **External Testing** → "+" to create group
   - Name: e.g., "Public Beta Testers"

2. **Add Testers**:
   - Enter email addresses (individually or CSV import)
   - Or create a **Public Link** for self-service signup (up to 10,000 users)

3. **Add Builds to Group**:
   - Select your external group
   - Click "+" to add a build
   - First external build requires **Beta App Review** (24-48 hours)

4. **Share Public Link** (optional):
   - Enable "Public Link" in group settings
   - Copy and share link (e.g., in GitHub README, documentation, or website)
   - Anyone with link can join (up to limit)

#### Step 6: Monitor and Iterate

1. **Check Crash Reports**:
   - Go to **TestFlight** → **Crashes** tab
   - Review crash logs and stack traces (symbols required)

2. **Collect Feedback**:
   - Testers can send feedback via TestFlight app (shake device → "Send Beta Feedback")
   - Review feedback in App Store Connect → **TestFlight** → **Feedback**

3. **Update Builds**:
   - Increment `CFBundleVersion` in Info.plist (e.g., "1" → "2")
   - Repeat Archive → Upload → TestFlight steps
   - New builds become available to existing testers automatically

#### Troubleshooting TestFlight Deployment

**"No signing certificate found"**:
- Ensure your Apple Developer account is active and paid
- Xcode → Preferences → Accounts → Download Manual Profiles
- Or manually create a Distribution Certificate in Apple Developer Portal

**"Missing compliance"**:
- Answer export compliance questions in App Store Connect
- For medical imaging apps without custom encryption: select "No"

**"Build stuck in processing"**:
- Processing typically takes 30 min - 2 hours
- If stuck >6 hours, contact Apple Developer Support
- Check App Store Connect email for rejection notices

**"TestFlight Beta Review rejected"**:
- Review rejection reason in email
- Common issues: missing privacy policy, unclear app description, missing demo account
- Update App Information in App Store Connect and resubmit

**"Invalid Bundle Identifier"**:
- Bundle ID in Info.plist must match App Store Connect record
- Bundle ID format: reverse-DNS notation (e.g., `com.company.appname`)
- Cannot change Bundle ID after app creation

#### TestFlight Limits

| Limit Type | Value |
|------------|-------|
| Internal Testers | 100 (must be App Store Connect team members) |
| External Testers | 10,000 per app |
| Builds per App | 100 active builds (older builds auto-expire) |
| Build Expiry | 90 days from upload |
| Beta Review | Required for first external build only (updates auto-approved) |
| Install Devices | 30 devices per tester |

#### Resources

- **TestFlight Documentation**: [https://developer.apple.com/testflight/](https://developer.apple.com/testflight/)
- **App Store Connect Help**: [https://help.apple.com/app-store-connect/](https://help.apple.com/app-store-connect/)
- **Distribution Guide**: [https://developer.apple.com/distribute/](https://developer.apple.com/distribute/)
- **Developer Forums**: [https://developer.apple.com/forums/](https://developer.apple.com/forums/)

## Using Sample DICOM Files

### Included Sample File

The example app includes a sample CT DICOM file for testing:

- **Location**: `Examples/DicomSwiftUIExample/Resources/sample.dcm`
- **Modality**: CT (Computed Tomography)
- **Size**: 512×512 pixels
- **Type**: 16-bit grayscale synthetic test image

### Loading DICOM Files

The example app uses a file picker to load DICOM files:

1. Launch the application
2. Select an example from the sidebar (e.g., "Image View", "Windowing Controls")
3. Click the "Select DICOM File" or "Select File..." button
4. Navigate to a DICOM file (.dcm extension)
5. The image will load and display with the selected demonstration mode

### Additional Test Files

More synthetic test files are available in the test fixtures directory:

```text
Tests/DicomCoreTests/Fixtures/
├── CT/ct_synthetic.dcm          # CT scan (512×512)
├── MR/mr_synthetic.dcm          # MR scan (256×256)
├── XR/xr_synthetic.dcm          # X-Ray (1024×1024)
├── US/us_synthetic.dcm          # Ultrasound (640×480)
└── Compressed/                   # JPEG-compressed samples
    └── jpeg_baseline_synthetic.dcm
```

### Getting Real DICOM Files

For testing with real medical imaging data, you can download sample DICOM files from:

- **Medical Connections DICOM Library**: [https://www.medicalconnections.co.uk/FreeDICOMData](https://www.medicalconnections.co.uk/FreeDICOMData)
- **TCIA (The Cancer Imaging Archive)**: [https://www.cancerimagingarchive.net](https://www.cancerimagingarchive.net)
- **OsiriX DICOM Sample Images**: [https://www.osirix-viewer.com/resources/dicom-image-library/](https://www.osirix-viewer.com/resources/dicom-image-library/)

**Note**: Always ensure you have appropriate permissions and comply with data privacy regulations when using real medical imaging data.

## Component Examples

### 1. DicomImageView Examples

**Location**: `Views/ImageViewExample.swift`

Demonstrates:
- Basic image loading from URL
- Automatic optimal windowing
- Medical presets (lung, bone, brain, etc.)
- Custom window/level values
- GPU acceleration with Metal

**Code Examples**:

```swift
// Basic usage
DicomImageView(url: dicomURL)

// Automatic windowing
DicomImageView(
    url: dicomURL,
    windowingMode: .automatic
)

// CT lung preset
DicomImageView(
    url: dicomURL,
    windowingMode: .preset(.lung)
)

// Custom window/level
DicomImageView(
    url: dicomURL,
    windowingMode: .custom(center: 50.0, width: 400.0)
)

// GPU accelerated
DicomImageView(
    url: dicomURL,
    windowingMode: .automatic,
    processingMode: .metal
)
```

### 2. WindowingControlView Examples

**Location**: `Views/WindowingExample.swift`

Demonstrates:
- Interactive window/level sliders
- Preset selection buttons
- Automatic optimal window calculation
- GPU vs CPU processing comparison
- Real-time image updates

### 3. SeriesNavigatorView Examples

**Location**: `Views/SeriesNavigatorExample.swift`

Demonstrates:
- Loading multi-slice DICOM series from directory
- Slice navigation with slider and buttons
- Current slice position indicator
- Series metadata display
- Playback controls

### 4. MetadataView Examples

**Location**: `Views/MetadataExample.swift`

Demonstrates:
- Displaying DICOM metadata tags
- Formatted patient, study, and series information
- Technical image parameters
- Searchable tag list
- Copy-to-clipboard functionality

## Architecture

The example app follows SwiftUI best practices:

- **State Management**: Uses `@State` and `@Binding` for reactive UI updates
- **Navigation**: Master-detail layout with `NavigationView`
- **File Handling**: Native `NSOpenPanel` for file selection
- **Error Handling**: Graceful error display with user-friendly messages
- **Accessibility**: VoiceOver labels and semantic descriptions
- **Dark Mode**: Automatic adaptation to system appearance

## Project Structure

```text
DicomSwiftUIExample/
├── DicomSwiftUIExampleApp.swift    # App entry point
├── ContentView.swift                # Main navigation view
├── Views/                           # Component examples
│   ├── ImageViewExample.swift
│   ├── WindowingExample.swift
│   ├── SeriesNavigatorExample.swift
│   └── MetadataExample.swift
├── Resources/                       # Sample files
│   └── sample.dcm
└── README.md                        # This file
```

## Code Patterns

All example views follow consistent patterns:

1. **State declarations** at the top using `@State`
2. **Enum-based demo modes** for switching between examples
3. **Body composition** with clear view builders
4. **Control panels** separate from image display
5. **Code snippets** showing the active example
6. **Helper methods** for file selection and formatting
7. **SwiftUI previews** for Xcode canvas support

## Troubleshooting

### App Won't Launch

- Ensure you're running from the repository root: `swift run DicomSwiftUIExample`
- Check that all dependencies are resolved: `swift package resolve`
- Verify Swift toolchain version: `swift --version` (requires a 6.2+ toolchain)

### File Won't Load

- Confirm file has `.dcm` extension
- Verify file is a valid DICOM format (not DICOMDIR or multi-frame)
- Check console output for specific error messages
- Try one of the included test files first

### Image Appears Black

- DICOM file may have embedded windowing that doesn't match content
- Try "Automatic Windowing" mode to recalculate optimal values
- Check that file contains pixel data (some DICOM files are metadata-only)

### Performance Issues

- Large images (>2048×2048) may be slow without GPU acceleration
- Enable GPU mode via `.processingMode: .metal` parameter
- Consider using `.auto` processing mode for adaptive selection

## Learning Resources

### DicomSwiftUI Documentation

- **API Reference**: Run `swift package generate-documentation` and open DocC archive
- **Source Code**: Browse `Sources/DicomSwiftUI/` for component implementations
- **Tests**: See `Tests/DicomSwiftUITests/` for unit test examples

### DicomCore Documentation

- **Repository README**: Architecture, package layout, and integration guidance in the [DICOM-Swift README](https://github.com/ThalesMMS/DICOM-Swift/blob/main/README.md)
- **API Reference**: See `Sources/DicomCore/` for core DICOM parsing
- **DICOM Standard**: [https://www.dicomstandard.org](https://www.dicomstandard.org)

## Contributing

Found a bug or want to improve an example? Contributions are welcome!

1. Check existing issues or create a new one
2. Fork the repository
3. Create a feature branch
4. Make your changes with tests
5. Submit a pull request

## License

This example application is part of the DICOM-Swift library and shares the same license. See LICENSE file in repository root for details.

## Support

- **Issues**: [GitHub Issues](https://github.com/ThalesMMS/DICOM-Swift/issues)
- **Documentation**: See the [DICOM-Swift README](https://github.com/ThalesMMS/DICOM-Swift/blob/main/README.md) and [Getting Started](https://github.com/ThalesMMS/DICOM-Swift/blob/main/GETTING_STARTED.md)
- **DICOM Questions**: Refer to [DICOM Standard](https://dicom.nema.org/medical/dicom/current/output/html/)

---

**Note**: This example uses synthetic test data. For production applications, always ensure proper handling of patient data privacy (HIPAA, GDPR) and implement appropriate security measures.
