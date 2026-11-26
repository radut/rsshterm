// Swift's MainActor runs on the dispatch main queue; GTK's GLib main loop never drains that queue on Linux, so
// `Task { @MainActor in … }` and every @MainActor model's async work would hang. libdispatch exposes the queue's
// wake-up eventfd for CoreFoundation's run loop; GLib watches it here and drains the queue on the GTK thread.
import CGtk
import Foundation
import Observation

@_silgen_name("_dispatch_get_main_queue_port_4CF") private func dispatchMainQueuePort() -> Int32
@_silgen_name("_dispatch_main_queue_callback_4CF") private func dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)

enum MainActorPump {
    private nonisolated(unsafe) static var installed = false

    /// Call once on the main thread before the first main-actor task.
    static func install() {
        guard !installed else { return }
        installed = true
        let fd = dispatchMainQueuePort()
        let cb: GUnixFDSourceFunc = { fd, _, _ in
            var value: UInt64 = 0
            _ = read(fd, &value, 8) // reset the eventfd
            dispatchMainQueueCallback(nil)
            return 1 // G_SOURCE_CONTINUE
        }
        g_unix_fd_add(fd, G_IO_IN, cb, nil)
        // Work queued before the watch existed.
        onMain { dispatchMainQueueCallback(nil) }
    }
}

/// Re-runs `render` after anything `read` touched changes (Observation), on the GTK main loop.
@MainActor
func observe(_ read: @escaping @MainActor () -> Void, then render: @escaping @MainActor () -> Void) {
    withObservationTracking(read) {
        Task { @MainActor in
            render()
            observe(read, then: render)
        }
    }
}

/// Starts main-actor async work from a GTK callback.
func run(_ work: @escaping @MainActor () async -> Void) {
    Task { @MainActor in await work() }
}
