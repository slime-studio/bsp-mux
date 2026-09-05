import Dispatch

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A `final class`, not a struct: the `DispatchSourceSignal` created per call must be retained
/// for the rest of the process's life (a source is cancelled the moment it's deallocated), so
/// this needs reference identity across calls rather than being a fresh value each time.
public final class RealSignalHandling: SignalHandling, @unchecked Sendable {
  /// Retained so it isn't deallocated (and implicitly cancelled) once `onSignal` returns - there's
  /// no "stop watching for this signal" use case, so the process exiting is what ends these, not
  /// ARC.
  private var retainedSources: [DispatchSourceSignal] = []

  public init() {}

  public func onSignal(_ signal: Int32, perform: @escaping @Sendable () -> Void) {
    // Required by Apple's own documented `DispatchSource` signal contract: dispatch's delivery
    // coexists with, but does not override, the process's actual signal disposition. Without
    // this, the default disposition (terminate) still fires and the process dies before `perform`
    // ever runs, making the whole mechanism silently inert. This also happens to be what makes
    // `ElectionEnvironment.signalOwnProcessGroup`'s self-delivery safe when called from a handler
    // registered here: it signals the whole process group including this process itself, and with
    // the signal already ignored, this process harmlessly no-ops on its own re-delivered signal
    // while other group members (the spawned backend, still at default disposition) actually
    // terminate.
    #if canImport(Darwin)
    Darwin.signal(signal, SIG_IGN)
    #elseif canImport(Glibc)
    Glibc.signal(signal, SIG_IGN)
    #endif

    let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
    source.setEventHandler(handler: perform)
    source.resume()
    retainedSources.append(source)
  }
}
