import Foundation

public struct RealProcessExiting: ProcessExiting {
  public init() {}

  public func exit(_ code: Int32) {
    Foundation.exit(code)
  }
}
