import Foundation
import UserNotifications

/// Base class for a Notification Service Extension, so rich push images render.
///
/// APNs cannot attach an image itself. The payload carries the URL and sets
/// `mutable-content`, and an extension **inside the host app** downloads it and
/// attaches it before the notification is displayed. Apple requires that
/// extension to be a separate target in the app, so an SDK cannot ship it for
/// you - only the logic that goes in it, which is what this class is.
///
/// ## Its own product, on purpose
///
/// This class used to live in the main `Joryio` module. An app extension may
/// link only extension-safe code, and `Joryio` is not: it calls
/// `UIApplication.shared` (push registration, badges, background flushes) and
/// pulls in SQLite for the event queue. Linking it into the extension either
/// failed review-time API checks or dragged the whole SDK into a process with
/// a 24 MB memory ceiling. So the extension gets a module with NO dependencies:
/// Foundation and UserNotifications only.
///
/// ## Adding it
///
/// 1. In Xcode: File > New > Target > **Notification Service Extension**.
/// 2. Add the extension product to that new target only:
///    - Swift Package Manager: `JoryioNotificationServiceExtension`
///    - CocoaPods: `pod 'Joryio/NotificationServiceExtension'` in the
///      extension's target block
/// 3. Replace the generated class with:
///
/// ```swift
/// import JoryioNotificationServiceExtension   // CocoaPods: import Joryio
///
/// class NotificationService: JoryioNotificationService {}
/// ```
///
/// That is the whole integration. Override `didReceive` if the app needs to do
/// its own work as well, and call `super`.
open class JoryioNotificationService: UNNotificationServiceExtension {

    /// The push data contract's image key. Must equal
    /// `PushPayloadKeys.imageUrl`; a unit test pins the two together.
    public static let imageUrlKey = "jry_image_url"

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    /// How long we allow the image download. The system gives an extension ~30s
    /// total and then calls `serviceExtensionTimeWillExpire`; staying well under
    /// that means the notification is delivered WITH its image rather than being
    /// force-delivered without one.
    open var imageDownloadTimeout: TimeInterval { 10 }

    /// Cap on the downloaded image. A notification attachment does not need more,
    /// and an extension has a hard memory limit (24MB) that a large image can
    /// blow - taking the notification with it.
    open var maxImageBytes: Int { 10 * 1024 * 1024 }

    override open func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let mutable else {
            contentHandler(request.content)
            return
        }
        deliverLock.lock()
        self.contentHandler = contentHandler
        self.bestAttempt = mutable
        deliverLock.unlock()

        // Accept either key: `jry_image_url` is what the Joryio backend sends
        // (the push data contract; `PushPayloadKeys.imageUrl` in the main
        // module, spelled out here because this module deliberately depends on
        // nothing), and `attachment-url` is the convention several other tools
        // use, so an app migrating to us does not have to re-author payloads.
        let raw = (request.content.userInfo[Self.imageUrlKey] as? String)
            ?? (request.content.userInfo["attachment-url"] as? String)

        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
            // No image, or not https. Deliver the notification unchanged rather
            // than dropping it - a missing picture must never cost the message.
            deliver()
            return
        }

        download(url) { [weak self] fileURL in
            guard let self else { return }
            defer { self.deliver() }
            guard let fileURL,
                  let attachment = try? UNNotificationAttachment(identifier: "joryio-image", url: fileURL)
            else { return }
            self.deliverLock.lock()
            self.bestAttempt?.attachments = [attachment]
            self.deliverLock.unlock()
        }
    }

    /// The system is out of patience: deliver whatever we have, with or without
    /// the image. Failing to call the handler here means the user sees NOTHING.
    override open func serviceExtensionTimeWillExpire() {
        deliver()
    }

    /// Guards `contentHandler` / `bestAttempt`. The download completes on a
    /// URLSession queue and `serviceExtensionTimeWillExpire` arrives on the
    /// extension's own thread; both call `deliver()`.
    private let deliverLock = NSLock()

    /// Hand the content to the system exactly once.
    ///
    /// Taking the handler and clearing it used to be two unsynchronised steps:
    /// a download finishing just as the system's deadline fired could see the
    /// handler in both threads and call it twice - undefined behaviour the
    /// documentation warns about. The take is now one locked step.
    func deliver() {
        deliverLock.lock()
        let handler = contentHandler
        let content = bestAttempt
        contentHandler = nil
        bestAttempt = nil
        deliverLock.unlock()
        guard let handler, let content else { return }
        handler(content)
    }

    /// Test seam: install a handler and content as `didReceive` would.
    func prepareForTesting(content: UNMutableNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        deliverLock.lock()
        contentHandler = handler
        bestAttempt = content
        deliverLock.unlock()
    }

    private func download(_ url: URL, completion: @escaping (URL?) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = imageDownloadTimeout
        config.timeoutIntervalForResource = imageDownloadTimeout

        URLSession(configuration: config).downloadTask(with: url) { [weak self] temp, response, _ in
            guard let self, let temp else { return completion(nil) }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return completion(nil)
            }
            // The size alone, through URL resource values: no file-timestamp
            // API, so the extension uses no required-reason API at all.
            let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > self.maxImageBytes { return completion(nil) }

            // The attachment must keep a file extension the system recognises, or
            // UNNotificationAttachment rejects it. The download's temp file has
            // none, so move it alongside with the URL's extension preserved.
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try FileManager.default.moveItem(at: temp, to: dest)
                completion(dest)
            } catch {
                completion(nil)
            }
        }.resume()
    }
}
