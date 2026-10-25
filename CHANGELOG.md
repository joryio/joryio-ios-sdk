# Changelog

## 1.3.2 - 2026-10-25

Added: `InAppConfig.holdInAppMessagesForHandler` (off by default). An app that draws in-app messages itself and calls `setInAppMessageCallback` after `initialize()` could have the first message drawn by the SDK: the sync `initialize()` starts could finish before the callback was set. With the option on, a message that is ready before the callback is held - not drawn, not reported, nothing spent, keeping the display slot - and handed to the callback when it is set; `clearInAppMessageCallback()` instead ends the hold and the SDK draws the held message. A reset or an identity, opt-out or consent change drops a held message. A `clearInAppMessageCallback()` made before a deferred `initialize()` (first unlock) is now applied at init too. A held message is bound to the person it was chosen for: delivery re-checks the anonymous id, user id and age (at most 5 minutes) as well. The same option, by the same name, on Android, React Native and Unity.

## 1.3.1 - 2026-10-24

Fixed: apps with an iOS 14 deployment target failed to build when Swift Package Manager resolved SQLite.swift 0.17.0 or newer (it requires iOS 15; reported by Xcode 16.3 and later). The package now accepts SQLite.swift from 0.15.0 up to, but not including, 0.17.0, so a fresh resolve picks 0.16.x.

Fixed: an HTML modal or slide-up could grow but never shrink - a modal started at 240pt, so an 80pt message kept a 240pt frame. The height is now measured from the message body, so a short message is as short as its content and a message re-fits when it gets shorter (a form replaced by its thank-you line). Heights stay capped at 90% of the screen; the message now scrolls inside beyond the cap instead of being cut off.

Added: `InAppCampaign.maxWidth` for HTML modals and slide-ups (points, set by the "Max width" field in the dashboard; modal 600 and slide-up 400 when unset), with `InAppSizing` helpers. `JoryioUI` lays a modal out centred at min(maxWidth, width - 2x24) and a slide-up at min(maxWidth, width - 2x12), and re-fits on rotation and split view. Before, these messages were full width on iPad.

Swift Package Manager is the supported way to install the SDK; see the README for moving from CocoaPods.

## 1.3.0 - 2026-10-06

First public release.
