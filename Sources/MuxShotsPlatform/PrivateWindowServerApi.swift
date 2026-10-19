import CoreGraphics

// Private SkyLight symbols, read-only: whether a window is shown on any Space.

@_silgen_name("CGSMainConnectionID")
func cgsMainConnectionId() -> Int32

@_silgen_name("CGSWindowIsOrderedIn")
func cgsWindowIsOrderedIn(_ connectionId: Int32, _ windowId: CGWindowID, _ isOrderedIn: UnsafeMutablePointer<Bool>) -> CGError
