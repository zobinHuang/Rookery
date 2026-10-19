import ApplicationServices

// Private HIServices symbols, read-only: window-server identity and lookup of windows on other Spaces.

@_silgen_name("_AXUIElementGetWindow")
func axUIElementGetWindow(_ element: AXUIElement, _ windowId: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
func axUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?
