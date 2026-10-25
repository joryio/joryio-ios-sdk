# Changelog

## 1.3.1 - 2026-10-24

Fixed: apps with an iOS 14 deployment target failed to build when Swift Package Manager resolved SQLite.swift 0.17.0 or newer (it requires iOS 15; reported by Xcode 16.3 and later). The package now accepts SQLite.swift from 0.15.0 up to, but not including, 0.17.0, so a fresh resolve picks 0.16.x.

Fixed: an HTML modal or slide-up could grow but never shrink - a modal started at 240pt, so an 80pt message kept a 240pt frame. The height is now measured from the message body, so a short message is as short as its content and a message re-fits when it gets shorter (a form replaced by its thank-you line). Heights stay capped at 90% of the screen; the message now scrolls inside beyond the cap instead of being cut off.

Added: `InAppCampaign.maxWidth` for HTML modals and slide-ups (points, set by the "Max width" field in the dashboard; modal 600 and slide-up 400 when unset), with `InAppSizing` helpers. `JoryioUI` lays a modal out centred at min(maxWidth, width - 2x24) and a slide-up at min(maxWidth, width - 2x12), and re-fits on rotation and split view. Before, these messages were full width on iPad.

Swift Package Manager is the supported way to install the SDK; see the README for moving from CocoaPods.

## 1.3.0 - 2026-10-06

First public release.
