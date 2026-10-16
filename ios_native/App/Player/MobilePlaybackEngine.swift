#if os(iOS)
import Foundation

extension FLVLivePlayer: MobilePlaybackEngine {
    @MainActor var diagnosticFields: [String: String] {
        ["player": diagnosticID, "state": String(describing: state), "bytes": String(receivedBytes),
         "pipeline": pipelineDiagnostics, "bufferSeconds": String(bufferedSeconds),
         "bufferBytes": String(bufferedBytes), "renewing": String(isRenewingStream)]
    }
}
#endif
