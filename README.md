# Spinosis iOS SDK

Swift client for a **bare UIKit / SwiftUI iOS app**. It talks to the same assignment and event APIs as the React Native SDK.

The customer's onboarding must never hang. If Spinosis is slow or offline, `getVariant` returns the cached assignment or the fallback.

## Add the package

In Xcode:

1. **File → Add Package Dependencies…**
2. Paste:

```text
https://github.com/ekofi/spinosis-ios
```

3. Dependency Rule: **Up to Next Major Version** from `1.0.0`
4. Add the **Spinosis** library to your app target

Or in another `Package.swift`:

```swift
.package(url: "https://github.com/ekofi/spinosis-ios.git", from: "1.0.0")
```

## Usage

```swift
import Spinosis

await Spinosis.initialize(
  apiKey: "spn_live_xxx",
  userId: currentUser.id,          // same ID as RevenueCat.appUserID
  apiUrl: "https://spinosis.com"
)

let variant = await Spinosis.getVariant(
  "onboarding_v1",
  fallback: "control",
  timeout: 1.5
)

if variant == "variant_b" {
  showNewOnboarding()
} else {
  showCurrentOnboarding()
}

await Spinosis.track("onboarding_completed", properties: ["steps": 5])
```

Call `initialize` at launch (for example in `App.init` or `application(_:didFinishLaunchingWithOptions:)`). Call `getVariant` before you pick an onboarding screen.

Anonymous users work if you omit `userId`. An ID is stored in `UserDefaults`.

## RevenueCat

Use the **same string** for:

- `Spinosis.initialize(userId:)`
- `Purchases.configure` / `Purchases.logIn` App User ID

Otherwise purchases cannot be attributed to the variant.

## Simulator against localhost

App Transport Security blocks `http://`. Either use `https://spinosis.com`, or add an ATS exception for your Mac's LAN IP while developing.
