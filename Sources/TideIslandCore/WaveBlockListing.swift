import Foundation

/// Parses supplied 0.14.5 CLI output in memory. Does not run wsh, authenticate,
/// persist raw output, or interpret a missing result as a closed target.
public enum WaveBlockListing {
    public static let maximumBytes = 1024 * 1024
    public static let maximumRows = 4096

    public static func location(stdout: Data, stderr: Data, exitCode: Int32, blockID: UUID,
                                expectedTabID: UUID? = nil, expectedWorkspaceID: UUID? = nil,
                                waveVersion: String, observedAt: Date) -> WaveLocation? {
        guard exitCode == 0, stderr.isEmpty, stdout.count <= maximumBytes,
              waveVersion == WaveLocation.reviewedWaveVersion,
              let rows = try? ConfigurationJSON.decode(stdout).array,
              !rows.isEmpty, rows.count <= maximumRows else { return nil }
        var blocks: Set<UUID> = []
        var workspacesByTab: [UUID: UUID] = [:]
        var result: WaveLocation?
        for row in rows {
            guard let fields = row.object,
                  let blockText = fields["blockid"]?.string, let block = WaveLocation.fullID(blockText),
                  let tabText = fields["tabid"]?.string, let tab = WaveLocation.fullID(tabText),
                  let workspaceText = fields["workspaceid"]?.string,
                  let workspace = WaveLocation.fullID(workspaceText),
                  blocks.insert(block).inserted,
                  expectedTabID.map({ $0 == tab }) != false,
                  expectedWorkspaceID.map({ $0 == workspace }) != false,
                  workspacesByTab[tab].map({ $0 == workspace }) != false else { return nil }
            workspacesByTab[tab] = workspace
            if block == blockID {
                // windowid is deliberately omitted: the reviewed CLI DTO does
                // not expose the backend's window field. meta is never copied.
                result = WaveLocation(blockID: block, tabID: tab, workspaceID: workspace,
                                      waveVersion: waveVersion, observedAt: observedAt, source: .blockListing)
            }
        }
        guard let result, (try? result.validate()) != nil else { return nil }
        return result
    }
}
