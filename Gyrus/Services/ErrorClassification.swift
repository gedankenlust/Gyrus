import Foundation

extension Error {
    /// Superseded work (a debounced search, a view switch, a library reset)
    /// cancels its task or request. That is never a failure the user needs to see.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if case .networkError(let inner)? = self as? APIError { return inner.isCancellation }
        let nsError = self as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Failures expected while the backend restarts or the network drops.
    /// Background work hits these routinely and retries on its own, so they
    /// are not worth an error toast; a user's own action still reports them.
    var isTransientBackendFailure: Bool {
        if case .networkError(let inner)? = self as? APIError,
           let urlError = inner as? URLError,
           urlError.code == .cannotConnectToHost ||
           urlError.code == .notConnectedToInternet ||
           urlError.code == .networkConnectionLost {
            return true
        }
        if case .serverError(let code)? = self as? APIError,
           code == 404 || code == 501 || code >= 500 {
            return true
        }
        return false
    }
}
