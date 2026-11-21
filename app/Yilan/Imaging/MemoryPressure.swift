import Dispatch
import Foundation

/// 系统内存紧张时清掉图片缓存（大图缓存、缩略图内存缓存），正在显示的图片不受影响
@MainActor
enum MemoryPressureMonitor {
    private static var source: DispatchSourceMemoryPressure?

    static func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let event = MemoryPressureMonitor.source?.data ?? []
                Log.app.notice("内存紧张（\(event.contains(.critical) ? "critical" : "warning", privacy: .public)），清理图片缓存")
                trim()
            }
        }
        source.activate()
        self.source = source
    }

    static func trim() {
        ThumbnailStore.shared.trimMemory()
        ThumbnailStore.large.trimMemory()
        Task { await ImagePipeline.shared.trimMemory() }
    }
}
