import CoreGraphics

// Private SkyLight symbols, read-only: window ordering and Space membership.

@_silgen_name("CGSMainConnectionID")
func cgsMainConnectionId() -> Int32

@_silgen_name("CGSWindowIsOrderedIn")
func cgsWindowIsOrderedIn(_ connectionId: Int32, _ windowId: CGWindowID, _ isOrderedIn: UnsafeMutablePointer<Bool>) -> CGError

@_silgen_name("CGSCopySpacesForWindows")
func cgsCopySpacesForWindows(_ connectionId: Int32, _ mask: Int32, _ listWindowIds: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopyManagedDisplaySpaces")
func cgsCopyManagedDisplaySpaces(_ connectionId: Int32) -> Unmanaged<CFArray>?
