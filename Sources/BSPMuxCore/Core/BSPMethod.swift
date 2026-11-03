/// BSP method names this codebase gives special meaning to. Everything else is opaque to us
/// by design — see `BSPOverlay` — so this is deliberately a short list, not a full BSP method
/// registry.
extension String {
  static let buildInitialize = "build/initialize"
  static let buildInitialized = "build/initialized"
  static let buildShutdown = "build/shutdown"
  static let buildExit = "build/exit"
  static let buildLogMessage = "build/logMessage"
  static let originId = "originId"
  /// Not a real BSP method - `bsp-mux stop`'s own control message, namespaced under `bspMux/`
  /// (rather than a real backend's own vendor namespace, e.g. `sourcekit-xcode-bsp/...`) so it
  /// can never collide with anything a real backend defines.
  static let bspMuxStop = "bspMux/stop"
}
