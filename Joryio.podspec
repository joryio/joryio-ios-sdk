Pod::Spec.new do |s|
  s.name             = 'Joryio'
  # Keep in sync with the other SDKs - sdk-version-parity.spec.ts pins it.
  s.version          = '1.3.2'
  s.summary          = 'Joryio iOS SDK - identify, track, push, and in-app messaging.'
  s.description      = <<-DESC
    Official Joryio SDK for iOS: user identification, event tracking with
    offline batching, push notifications (APNS), in-app messaging, and
    e-commerce tracking helpers.
  DESC
  s.homepage         = 'https://joryio.com'
  s.license          = { :type => 'Commercial', :file => 'LICENSE' }
  s.author           = { 'Joryio' => 'support@joryio.com' }
  # CocoaPods requires a source; the git URL is the canonical distribution
  # point once the SDK repo is published. The React Native podspec depends on
  # this pod ("Joryio", "~> 1.0"), which is why it must exist.
  s.source           = { :git => 'https://github.com/joryio/joryio-ios-sdk.git', :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'
  s.swift_version    = '5.9'

  # Subspecs mirror the SwiftPM products, so a CocoaPods consumer gets the same
  # choice: `pod 'Joryio'` is tracking/identity/push with NO WebKit and no
  # message views linked; `pod 'Joryio/UI'` adds in-app rendering.
  #
  # `Core` is the default subspec, so a bare `pod 'Joryio'` stays UI-free. That
  # is deliberate: an integrator who has not asked for in-app rendering should
  # not silently link a web view.
  s.default_subspec  = 'Core'

  s.subspec 'Core' do |core|
    core.source_files = 'Sources/Joryio/**/*.swift'
    # Apple's privacy manifest (required-reason API: UserDefaults CA92.1;
    # collected data types). A resource bundle, so it reaches the app - and
    # every pod that depends on this one (React Native, Unity) - unchanged.
    core.resource_bundles = { 'Joryio_Privacy' => ['Sources/Joryio/PrivacyInfo.xcprivacy'] }
    # Mirrors Package.swift. Declared on the subspec, not the pod, so the
    # extension subspec below does not inherit it.
    core.dependency 'SQLite.swift', '~> 0.15'
  end

  s.subspec 'UI' do |ui|
    ui.source_files   = 'Sources/JoryioUI/**/*.swift'
    ui.dependency 'Joryio/Core'
  end

  # For the Notification Service Extension target ONLY: `JoryioNotificationService`
  # with no dependencies, so the extension links no UIApplication-using code
  # and no SQLite. Add it in the extension's target block:
  #
  #   target 'NotificationService' do
  #     pod 'Joryio/NotificationServiceExtension'
  #   end
  #
  # Subspecs share the pod's module, so the extension writes `import Joryio`.
  s.subspec 'NotificationServiceExtension' do |ext|
    ext.source_files = 'Sources/JoryioNotificationServiceExtension/**/*.swift'
  end
end
