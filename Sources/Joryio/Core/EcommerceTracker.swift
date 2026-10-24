import Foundation

// MARK: - E-Commerce Types

/// Represents a product for e-commerce tracking
public struct EcommerceProduct {
    public let productId: String
    public let name: String
    public let price: Double
    public var quantity: Int?
    public var category: String?
    public var brand: String?
    public var variant: String?
    public var variantId: String?
    public var sku: String?
    public var imageUrl: String?
    public var url: String?

    public init(
        productId: String,
        name: String,
        price: Double,
        quantity: Int? = nil,
        category: String? = nil,
        brand: String? = nil,
        variant: String? = nil,
        variantId: String? = nil,
        sku: String? = nil,
        imageUrl: String? = nil,
        url: String? = nil
    ) {
        self.productId = productId
        self.name = name
        self.price = price
        self.quantity = quantity
        self.category = category
        self.brand = brand
        self.variant = variant
        self.variantId = variantId
        self.sku = sku
        self.imageUrl = imageUrl
        self.url = url
    }

    func toProperties() -> [String: Any] {
        var props: [String: Any] = [
            "product_id": productId,
            "name": name,
            "price": price
        ]
        if let quantity = quantity { props["quantity"] = quantity }
        if let category = category { props["category"] = category }
        if let brand = brand { props["brand"] = brand }
        if let variant = variant { props["variant"] = variant }
        if let variantId = variantId { props["variant_id"] = variantId }
        if let sku = sku { props["sku"] = sku }
        if let imageUrl = imageUrl { props["image_url"] = imageUrl }
        if let url = url { props["url"] = url }
        return props
    }
}

/// Represents a cart item (product with quantity)
public struct EcommerceCartItem {
    public let product: EcommerceProduct
    public let quantity: Int

    public init(product: EcommerceProduct, quantity: Int) {
        self.product = product
        self.quantity = quantity
    }

    public init(
        productId: String,
        name: String,
        price: Double,
        quantity: Int,
        category: String? = nil,
        brand: String? = nil,
        variant: String? = nil,
        variantId: String? = nil,
        sku: String? = nil,
        imageUrl: String? = nil,
        url: String? = nil
    ) {
        self.product = EcommerceProduct(
            productId: productId,
            name: name,
            price: price,
            quantity: quantity,
            category: category,
            brand: brand,
            variant: variant,
            variantId: variantId,
            sku: sku,
            imageUrl: imageUrl,
            url: url
        )
        self.quantity = quantity
    }

    var itemTotal: Double {
        return product.price * Double(quantity)
    }

    func toProperties() -> [String: Any] {
        var props = product.toProperties()
        props["quantity"] = quantity
        return props
    }
}

/// Represents an order
public struct EcommerceOrder {
    public let orderId: String
    public let items: [EcommerceCartItem]
    public let value: Double
    public var currency: String?
    public var shipping: Double?
    public var tax: Double?
    public var discount: Double?
    public var coupon: String?

    public init(
        orderId: String,
        items: [EcommerceCartItem],
        value: Double,
        currency: String? = nil,
        shipping: Double? = nil,
        tax: Double? = nil,
        discount: Double? = nil,
        coupon: String? = nil
    ) {
        self.orderId = orderId
        self.items = items
        self.value = value
        self.currency = currency
        self.shipping = shipping
        self.tax = tax
        self.discount = discount
        self.coupon = coupon
    }

    var itemCount: Int {
        return items.reduce(0) { $0 + $1.quantity }
    }
}

/// Configuration for e-commerce tracking: the default currency. The same
/// single option as Android (the unused `trackPageViews` / `trackAddToCart`
/// flags, which nothing read, are gone on both).
public struct EcommerceConfig {
    public var currency: String

    public init(currency: String = "USD") {
        self.currency = currency
    }
}

// MARK: - E-Commerce Tracker

/// E-Commerce tracking helper class
/// Provides standardized e-commerce event tracking
public class EcommerceTracker {
    private let sdk: Joryio
    private let config: EcommerceConfig

    public init(sdk: Joryio = .shared, config: EcommerceConfig = EcommerceConfig()) {
        self.sdk = sdk
        self.config = config
    }

    // MARK: - Required arguments (contract v4, 42)
    //
    // A call missing what makes the event meaningful - a product id, an
    // order id, a finite amount - logs a warning and sends NOTHING. It used
    // to send it anyway: `purchase` with an empty order id or a NaN total
    // became an "Order Completed" the revenue pipeline counted as a real
    // order. Never throws. ONE set on every Joryio SDK and wrapper (pinned by
    // the backend's ecommerce-guard-parity spec):
    //  - a product, and every cart/order line: a productId and a finite price;
    //  - cart calls: a finite cartValue; purchase: an orderId and a finite
    //    value (the items may be empty);
    //  - every other id or label: categoryId and categoryName, query,
    //    paymentMethod, shareMethod, orderId, couponCode;
    //  - an optional amount may be left out, but one given must be finite.
    // An id that is empty or only whitespace counts as missing.

    private func missing(_ method: String, _ what: String) -> Bool {
        sdk.logWarning("ecommerce.\(method) needs \(what); nothing was tracked")
        return true
    }

    private static func blank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True (and a warning) when `product` cannot be tracked.
    private func invalid(_ product: EcommerceProduct, in method: String) -> Bool {
        if Self.blank(product.productId) { return missing(method, "a productId") }
        if !product.price.isFinite { return missing(method, "a finite price") }
        return false
    }

    private func invalid(_ items: [EcommerceCartItem], in method: String) -> Bool {
        items.contains { invalid($0.product, in: method) }
    }

    /// True (and a warning) when a required text argument is blank.
    private func invalidText(_ value: String, _ name: String, in method: String) -> Bool {
        Self.blank(value) ? missing(method, "a \(name)") : false
    }

    private func invalidAmount(_ value: Double?, _ name: String, in method: String) -> Bool {
        guard let value, !value.isFinite else { return false }
        return missing(method, "a finite \(name)")
    }

    // MARK: - Product Events

    /// Track when a user views a product
    public func viewProduct(_ product: EcommerceProduct) {
        if invalid(product, in: "viewProduct") { return }
        var props = product.toProperties()
        props["currency"] = config.currency
        sdk.track("Product Viewed", properties: props)
    }

    /// Track when a user views a category/collection page
    public func viewCategory(categoryId: String, categoryName: String, properties: [String: Any] = [:]) {
        if invalidText(categoryId, "categoryId", in: "viewCategory")
            || invalidText(categoryName, "categoryName", in: "viewCategory") { return }
        var props: [String: Any] = [
            "category_id": categoryId,
            "category_name": categoryName
        ]
        props.merge(properties) { _, new in new }
        sdk.track("Product List Viewed", properties: props)
    }

    /// Track when a user searches for products
    public func search(query: String, resultCount: Int? = nil, properties: [String: Any] = [:]) {
        if invalidText(query, "query", in: "search") { return }
        var props: [String: Any] = ["query": query]
        if let resultCount = resultCount {
            props["result_count"] = resultCount
        }
        props.merge(properties) { _, new in new }
        sdk.track("Products Searched", properties: props)
    }

    // MARK: - Cart Events

    /// Track when a user adds an item to cart
    public func addToCart(item: EcommerceCartItem, cartValue: Double? = nil) {
        if invalid(item.product, in: "addToCart") || invalidAmount(cartValue, "cartValue", in: "addToCart") { return }
        var props = item.toProperties()
        props["item_total"] = item.itemTotal
        props["currency"] = config.currency
        if let cartValue = cartValue {
            props["cart_value"] = cartValue
        }
        sdk.track("Product Added", properties: props)
    }

    /// Track when a user removes an item from cart
    public func removeFromCart(product: EcommerceProduct, quantity: Int = 1) {
        if invalid(product, in: "removeFromCart") { return }
        var props: [String: Any] = [
            "product_id": product.productId,
            "name": product.name,
            "price": product.price,
            "quantity": quantity,
            "currency": config.currency
        ]
        if let variantId = product.variantId {
            props["variant_id"] = variantId
        }
        if let sku = product.sku {
            props["sku"] = sku
        }
        sdk.track("Product Removed", properties: props)
    }

    /// Track the cart being viewed.
    ///
    /// `Cart Viewed` has been canonical all along, but no tracker had a method
    /// for it - so the only way to send it was to type the name by hand, which
    /// is the habit these trackers exist to remove. Same payload as
    /// `updateCart`: the cart is the same thing either way.
    public func cartViewed(items: [EcommerceCartItem], cartValue: Double) {
        if invalid(items, in: "cartViewed") || invalidAmount(cartValue, "cartValue", in: "cartViewed") { return }
        let itemsData = items.map { item -> [String: Any] in
            var data: [String: Any] = [
                "product_id": item.product.productId,
                "name": item.product.name,
                "price": item.product.price,
                "quantity": item.quantity
            ]
            if let variantId = item.product.variantId {
                data["variant_id"] = variantId
            }
            if let sku = item.product.sku {
                data["sku"] = sku
            }
            return data
        }

        sdk.track("Cart Viewed", properties: [
            "items": itemsData,
            "item_count": items.reduce(0) { $0 + $1.quantity },
            "cart_value": cartValue,
            "currency": config.currency
        ])
    }

    /// Track when a user updates their cart
    public func updateCart(items: [EcommerceCartItem], cartValue: Double) {
        if invalid(items, in: "updateCart") || invalidAmount(cartValue, "cartValue", in: "updateCart") { return }
        let itemCount = items.reduce(0) { $0 + $1.quantity }
        let itemsData = items.map { item -> [String: Any] in
            var data: [String: Any] = [
                "product_id": item.product.productId,
                "name": item.product.name,
                "price": item.product.price,
                "quantity": item.quantity
            ]
            if let variantId = item.product.variantId {
                data["variant_id"] = variantId
            }
            if let sku = item.product.sku {
                data["sku"] = sku
            }
            return data
        }

        sdk.track("Cart Updated", properties: [
            "items": itemsData,
            "item_count": itemCount,
            "cart_value": cartValue,
            "currency": config.currency
        ])
    }

    // MARK: - Checkout Events

    /// Track when a user starts checkout
    public func startCheckout(items: [EcommerceCartItem], cartValue: Double, properties: [String: Any] = [:]) {
        if invalid(items, in: "startCheckout") || invalidAmount(cartValue, "cartValue", in: "startCheckout") { return }
        let itemCount = items.reduce(0) { $0 + $1.quantity }
        let itemsData = items.map { item -> [String: Any] in
            var data: [String: Any] = [
                "product_id": item.product.productId,
                "name": item.product.name,
                "price": item.product.price,
                "quantity": item.quantity
            ]
            if let variantId = item.product.variantId {
                data["variant_id"] = variantId
            }
            if let sku = item.product.sku {
                data["sku"] = sku
            }
            return data
        }

        var props: [String: Any] = [
            "items": itemsData,
            "item_count": itemCount,
            "value": cartValue,
            "currency": config.currency
        ]
        props.merge(properties) { _, new in new }
        sdk.track("Checkout Started", properties: props)
    }

    /// Track when a user adds payment info
    public func addPaymentInfo(paymentMethod: String, properties: [String: Any] = [:]) {
        if invalidText(paymentMethod, "paymentMethod", in: "addPaymentInfo") { return }
        var props: [String: Any] = ["payment_method": paymentMethod]
        props.merge(properties) { _, new in new }
        sdk.track("Payment Info Entered", properties: props)
    }

    // MARK: - Order Events

    /// Track when an order is placed
    ///
    /// Needs an `orderId` and a finite `value`, and every item a `productId`
    /// and a finite price: otherwise nothing is sent - never a zero order
    /// (contract v4, 42). The items may be empty, as on every other SDK.
    public func purchase(order: EcommerceOrder) {
        if Self.blank(order.orderId) { _ = missing("purchase", "an orderId"); return }
        if !order.value.isFinite { _ = missing("purchase", "a finite value"); return }
        if invalid(order.items, in: "purchase") { return }
        if invalidAmount(order.shipping, "shipping", in: "purchase")
            || invalidAmount(order.tax, "tax", in: "purchase")
            || invalidAmount(order.discount, "discount", in: "purchase") { return }
        let itemsData = order.items.map { item -> [String: Any] in
            var data: [String: Any] = [
                "product_id": item.product.productId,
                "name": item.product.name,
                "price": item.product.price,
                "quantity": item.quantity
            ]
            if let category = item.product.category {
                data["category"] = category
            }
            if let brand = item.product.brand {
                data["brand"] = brand
            }
            if let variantId = item.product.variantId {
                data["variant_id"] = variantId
            }
            if let sku = item.product.sku {
                data["sku"] = sku
            }
            return data
        }

        var props: [String: Any] = [
            // `total` and `orderId`, NOT `value` and `order_id`.
            //
            // The revenue pipeline reads exactly these two keys - see
            // purchase-vocabulary.ts, which says of `value`/`revenue`: "somebody
            // else's convention", and of `order_id`: "a key nothing reads".
            // Every purchase tracked through this tracker therefore landed as
            // ZERO revenue with no order id for attribution, on all three SDKs.
            //
            // Not a crash, not a warning: a $0 order that looks like an order.
            // The demo app hit the same thing and its comment already warned
            // about it - the SDK it was warning about never got fixed.
            "orderId": order.orderId,
            "items": itemsData,
            "item_count": order.itemCount,
            "total": order.value,
            "currency": order.currency ?? config.currency
        ]
        if let shipping = order.shipping { props["shipping"] = shipping }
        if let tax = order.tax { props["tax"] = tax }
        if let discount = order.discount { props["discount"] = discount }
        if let coupon = order.coupon { props["coupon"] = coupon }

        sdk.track("Order Completed", properties: props)
    }

    /// Track order fulfillment (shipped)
    public func orderFulfilled(orderId: String, trackingNumber: String? = nil, carrier: String? = nil) {
        if Self.blank(orderId) { _ = missing("orderFulfilled", "an orderId"); return }
        var props: [String: Any] = ["order_id": orderId]
        if let trackingNumber = trackingNumber { props["tracking_number"] = trackingNumber }
        if let carrier = carrier { props["carrier"] = carrier }
        sdk.track("Order Fulfilled", properties: props)
    }

    /// Track order delivery
    public func orderDelivered(orderId: String) {
        if Self.blank(orderId) { _ = missing("orderDelivered", "an orderId"); return }
        sdk.track("Order Delivered", properties: ["order_id": orderId])
    }

    /// Track order cancellation
    public func orderCancelled(orderId: String, reason: String? = nil) {
        if Self.blank(orderId) { _ = missing("orderCancelled", "an orderId"); return }
        var props: [String: Any] = ["order_id": orderId]
        if let reason = reason { props["reason"] = reason }
        sdk.track("Order Cancelled", properties: props)
    }

    /// Track order refund
    public func orderRefunded(orderId: String, refundAmount: Double? = nil, reason: String? = nil) {
        if Self.blank(orderId) { _ = missing("orderRefunded", "an orderId"); return }
        if invalidAmount(refundAmount, "refundAmount", in: "orderRefunded") { return }
        var props: [String: Any] = ["order_id": orderId]
        if let refundAmount = refundAmount { props["refund_amount"] = refundAmount }
        if let reason = reason { props["reason"] = reason }
        sdk.track("Order Refunded", properties: props)
    }

    // MARK: - Wishlist Events

    /// Track product added to wishlist
    public func addToWishlist(product: EcommerceProduct) {
        if invalid(product, in: "addToWishlist") { return }
        var props: [String: Any] = [
            "product_id": product.productId,
            "name": product.name,
            "price": product.price,
            "currency": config.currency
        ]
        if let category = product.category { props["category"] = category }
        if let brand = product.brand { props["brand"] = brand }
        sdk.track("Product Added to Wishlist", properties: props)
    }

    /// Track product removed from wishlist
    public func removeFromWishlist(product: EcommerceProduct) {
        if invalid(product, in: "removeFromWishlist") { return }
        sdk.track("Product Removed from Wishlist", properties: [
            "product_id": product.productId,
            "name": product.name
        ])
    }

    // MARK: - Engagement Events

    /// Track product shared
    public func shareProduct(product: EcommerceProduct, shareMethod: String) {
        if invalid(product, in: "shareProduct") || invalidText(shareMethod, "shareMethod", in: "shareProduct") { return }
        sdk.track("Product Shared", properties: [
            "product_id": product.productId,
            "name": product.name,
            "share_method": shareMethod
        ])
    }

    /// Track coupon applied
    public func applyCoupon(couponCode: String, discountAmount: Double? = nil, discountType: String? = nil) {
        if invalidText(couponCode, "couponCode", in: "applyCoupon")
            || invalidAmount(discountAmount, "discountAmount", in: "applyCoupon") { return }
        var props: [String: Any] = ["coupon_code": couponCode]
        if let discountAmount = discountAmount { props["discount_amount"] = discountAmount }
        if let discountType = discountType { props["discount_type"] = discountType }
        sdk.track("Coupon Applied", properties: props)
    }

    /// Track coupon removed
    public func removeCoupon(couponCode: String) {
        if invalidText(couponCode, "couponCode", in: "removeCoupon") { return }
        sdk.track("Coupon Removed", properties: ["coupon_code": couponCode])
    }

    /// Track product review submitted
    public func submitReview(productId: String, rating: Int, reviewText: String? = nil) {
        if Self.blank(productId) { _ = missing("submitReview", "a productId"); return }
        var props: [String: Any] = [
            "product_id": productId,
            "rating": rating
        ]
        if let reviewText = reviewText { props["review_text"] = reviewText }
        sdk.track("Product Reviewed", properties: props)
    }
}

// MARK: - Joryio Extension
//
// `ecommerce(config:)` deliberately lives ONLY on JoryioSDK.swift.
//
// A second declaration used to sit here, and because both carried a default
// argument every `Joryio.shared.ecommerce()` call was ambiguous - the SDK did
// not compile for an integrator who had to patch it out locally to ship.
//
// It was also the worse of the two: it built a NEW tracker on every call,
// where the surviving one caches `_ecommerce` and reuses it. So an app that
// called ecommerce() twice got two trackers and, with auto-tracking enabled,
// two of every event.
