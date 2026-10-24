# Changelog

## 1.3.1 - 2026-10-24

Fixed: apps with an iOS 14 deployment target failed to build when Swift Package Manager resolved SQLite.swift 0.17.0 or newer (it requires iOS 15; reported by Xcode 16.3 and later). The package now accepts SQLite.swift from 0.15.0 up to, but not including, 0.17.0, so a fresh resolve picks 0.16.x.

No API changes. Swift Package Manager is the supported way to install the SDK; see the README for moving from CocoaPods.

## 1.3.0 - 2026-10-06

First public release.
