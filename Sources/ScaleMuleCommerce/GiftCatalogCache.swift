import Foundation
import ScaleMuleCore

/// Session-local catalogue pages, never balances or purchase results. The store
/// owns the tenant boundary and clears this cache on sign-out via stop().
@MainActor
final class GiftCatalogCache {
    private struct PageKey: Hashable { let environment: CommerceEnvironment; let before: String? }
    private struct Page { let products: [GiftProduct]; let expires: TimeInterval }
    private var pages: [PageKey: Page] = [:]
    private var pending: [PageKey: Task<ApiResponse<[GiftProduct]>, Never>] = [:]
    private var generation = UUID()
    private let lifetime: TimeInterval
    private let now: () -> TimeInterval

    init(lifetime: TimeInterval = 300, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.lifetime = lifetime; self.now = now
    }

    func snapshot(environment: CommerceEnvironment, before: String? = nil) -> [GiftProduct]? {
        let key = PageKey(environment: environment, before: before)
        guard let page = pages[key], page.expires > now() else { pages[key] = nil; return nil }
        return page.products
    }

    func products(environment: CommerceEnvironment, before: String? = nil,
                  load: @escaping @MainActor () async -> ApiResponse<[GiftProduct]>) async -> ApiResponse<[GiftProduct]> {
        if let saved = snapshot(environment: environment, before: before) { return .success(saved) }
        let key = PageKey(environment: environment, before: before)
        let run = generation
        if let task = pending[key] {
            let response = await task.value
            guard generation == run else { return .failure(ApiError(code: .networkError, message: "Request cancelled.")) }
            return response
        }
        let task = Task { await load() }
        pending[key] = task
        let response = await task.value
        guard generation == run else {
            return .failure(ApiError(code: .networkError, message: "Request cancelled."))
        }
        pending[key] = nil
        if case .success(let products) = response {
            if pages.count >= 10, let oldest = pages.min(by: { $0.value.expires < $1.value.expires })?.key { pages[oldest] = nil }
            pages[key] = Page(products: products, expires: now() + lifetime)
        }
        return response
    }

    func clear() {
        generation = UUID(); pages = [:]
        pending.values.forEach { $0.cancel() }; pending = [:]
    }
}
