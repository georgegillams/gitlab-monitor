# GitLab Monitor

Menu-bar macOS app that shows your authored open merge requests, pipeline stages, and approvals.

## Features

- Menu-bar icon with a popover listing your open MRs
- Pipeline stage status icons (passed, paused, failed, cancelled, unknown)
- Approval counts and approver names
- Multiple GitLab instances (URL + bearer token; tokens in Keychain)
- Launch at login
- Manual refresh and last-updated timestamp
- Greys out data older than 5 minutes

## Requirements

- macOS 13.3+
- Xcode 15+
- GitLab personal access token with `read_api` (or `api`) scope

## Run

1. Open `GitLabMonitor.xcodeproj` in Xcode.
2. Select the **GitLabMonitor** scheme and Run.
3. Click the menu-bar icon → Settings → add your GitLab URL and token.

## Token storage

Personal access tokens are stored in the macOS data protection Keychain. They are not written to UserDefaults or the login keychain.

- Readable only while this Mac is unlocked.
- Not synced through iCloud Keychain, and excluded from backups.
- On a Mac with a login password, stored so that removing that password deletes them. A Mac with no password uses the strongest class macOS allows instead: this device only, while unlocked.

Instance URLs and labels stay in app settings. Only the tokens go in the Keychain.

## Design tokens

UI colors come from [components-swiftUI](https://github.com/georgegillams/components-swiftUI) (`Semantic.Colors`, `Primitive.Layout`).

## Release

### App Store (App Store Connect)

- Update version (marketing version) and build (needs incrementing). In Xcode: select **GitLabMonitor** target → **General** → **Identity** → **Version** / **Build**
- Take screenshots at 1280×800
- Clean
- Create build online at https://appstoreconnect.apple.com/
- Select non-debug scheme
- Archive
- Upload

Release archives use `GitLabMonitor-Release.entitlements` (App Sandbox enabled, with network client). No manual entitlements changes are needed before upload.

Note: If releasing for manual distribution, disable app sandboxing.
