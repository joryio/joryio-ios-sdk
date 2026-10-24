import UIKit
#if SWIFT_PACKAGE
// SwiftPM: JoryioUI is its own module. CocoaPods: Joryio/UI is a subspec
// compiled INTO the Joryio module, where this import is a warning that
// fails `pod lib lint` (and so `pod trunk push`).
import Joryio
#endif

/**
 The smallest image loader that does the job, deliberately.

 An SDK adding SDWebImage or Kingfisher imposes that dependency, and its
 version, on every integrating app. For one optional image in an in-app message
 that is a poor trade, so this is URLSession plus an NSCache.

 Behaviour that matters:
 - **https only.** An in-app image URL is authored content; http would let a
   campaign trigger cleartext traffic, which ATS blocks by default anyway.
 - **Fails invisibly.** A failed load HIDES the image view rather than leaving a
   blank 140dp gap in the middle of the message.
 - **Tag-checked.** The view records which URL it asked for, so a late response
   cannot paint over a message the user has already dismissed.
 */
enum ImageLoader {
    private static let cache = NSCache<NSString, UIImage>()

    /// Bytes, not entries: 20 small images and one enormous one are very
    /// different memory footprints, and only the second matters.
    private static let cacheLimitBytes = 8 * 1024 * 1024
    private static let maxBytes = 5 * 1024 * 1024

    static func load(_ urlString: String, into imageView: UIImageView) {
        guard urlString.lowercased().hasPrefix("https://"), let url = URL(string: urlString) else {
            imageView.isHidden = true
            return
        }

        cache.totalCostLimit = cacheLimitBytes

        if let cached = cache.object(forKey: urlString as NSString) {
            imageView.image = cached
            return
        }

        // Identify the pending request so a response arriving after the message
        // was dismissed (or reused) cannot fill the wrong view.
        imageView.accessibilityValue = urlString

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let data,
                data.count <= maxBytes,
                let image = UIImage(data: data)
            else {
                DispatchQueue.main.async {
                    guard imageView.accessibilityValue == urlString else { return }
                    // No broken-image placeholder: a message missing its picture
                    // still reads; a grey rectangle does not.
                    imageView.isHidden = true
                }
                return
            }

            DispatchQueue.main.async {
                guard imageView.accessibilityValue == urlString else { return }
                cache.setObject(image, forKey: urlString as NSString, cost: data.count)
                imageView.image = image
            }
        }.resume()
    }
}
