import Foundation
import Testing
@testable import TideIslandCore

private let waveEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private let waveBlock = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
private let waveTab = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
private let waveWorkspace = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!

@Test func oldEventsKeepOpaqueBlockIDsWithoutInventingStructuredLocations() throws {
    for version in [1, 2] {
        let event = AgentEvent(version: version, sessionID: "legacy", projectName: "project", phase: .working,
                               occurredAt: waveEpoch, waveBlockID: "block-1",
                               context: version == 2 ? EventContext(source: .manual, kind: .status, receivedAt: waveEpoch) : nil)
        let data = try EventCodec.encode(event)
        let decoded = try EventCodec.decode(data)
        #expect(decoded == event && decoded.waveLocation == nil && decoded.waveBlockID == "block-1")
        #expect(!String(decoding: data, as: UTF8.self).contains("waveLocation"))
    }
}

@Test func structuredLocationRoundTripsAllOptionalIDsWithoutChangingOuterVersion() throws {
    let location = WaveLocation(blockID: waveBlock, tabID: waveTab, workspaceID: waveWorkspace,
                                windowID: UUID(), waveVersion: "0.14.5", observedAt: waveEpoch, source: .blockListing)
    let event = waveEvent(location)
    let data = try EventCodec.encode(event)
    let decoded = try EventCodec.decode(data)
    #expect(decoded == event && decoded.version == 2 && decoded.waveLocation?.version == 1)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let metadata = try #require(object["waveLocation"] as? [String: Any])
    #expect(Set(metadata.keys) == ["version", "blockID", "tabID", "workspaceID", "windowID", "waveVersion", "observedAt", "source"])
}

@Test func invalidLocationVersionsClocksAndConflictingLegacyIDsRejectTheEvent() throws {
    let invalid = [
        WaveLocation(version: 99, blockID: waveBlock, observedAt: waveEpoch, source: .environment),
        WaveLocation(blockID: waveBlock, observedAt: Date(timeIntervalSince1970: .infinity), source: .environment),
        WaveLocation(blockID: waveBlock, waveVersion: "private-version\n", observedAt: waveEpoch, source: .environment),
    ]
    for location in invalid { #expect(throws: EventError.self) { try EventCodec.encode(waveEvent(location)) } }
    let location = waveLocation()
    for legacy in ["block-1", UUID().uuidString] {
        let conflicting = waveEvent(location, legacy: legacy)
        #expect(throws: EventError.self) { try EventCodec.encode(conflicting) }
    }
    let v1 = AgentEvent(sessionID: "legacy", projectName: "project", phase: .working, waveLocation: location)
    #expect(throws: EventError.self) { try EventCodec.encode(v1) }
}

@Test func malformedWireLocationsCannotBeSilentlyDowngradedToLegacyMetadata() throws {
    let data = try EventCodec.encode(waveEvent(waveLocation()))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let original = try #require(object["waveLocation"] as? [String: Any])
    for (field, value) in [("blockID", "this"), ("tabID", "tab:short"), ("source", "authenticated"), ("observedAt", "today")] {
        var changed = object, location = original
        location[field] = value; changed["waveLocation"] = location
        let invalid = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) { try EventCodec.decode(invalid) }
    }
}

@Test func environmentCaptureUsesOnlyAllowlistedMetadataAndKeepsOriginalObservationTime() throws {
    let values = ["WAVETERM_BLOCKID": waveBlock.uuidString, "WAVETERM_TABID": waveTab.uuidString,
                  "WAVETERM_VERSION": "0.14.5", "WAVETERM_JWT": "fixture-private-token",
                  "WAVE_AUTH_KEY": "fixture-private-auth", "WAVETERM_WINDOWID": UUID().uuidString,
                  "WAVETERM_WORKSPACEID": UUID().uuidString, "PWD": "/fixture-private-cwd"]
    let captured = WaveLocationCapture.environment(values, observedAt: waveEpoch)
    let location = try #require(captured.location)
    #expect(location.blockID == waveBlock && location.tabID == waveTab && location.waveVersion == "0.14.5")
    #expect(location.workspaceID == nil && location.windowID == nil && location.source == .environment)
    #expect(location.observedAt == waveEpoch)
    let encoded = String(decoding: try EventCodec.encode(waveEvent(location)), as: UTF8.self)
    #expect(!encoded.contains("fixture-private") && !encoded.contains("JWT") && !encoded.contains("PWD"))
}

@Test func malformedOptionalEnvironmentValuesStayPartialWithoutSuppressingLifecycleEvents() throws {
    let captured = WaveLocationCapture.environment(["WAVETERM_BLOCKID": waveBlock.uuidString,
                                                   "WAVETERM_TABID": "not-a-uuid", "WAVETERM_VERSION": "bad\nversion"],
                                                  observedAt: waveEpoch)
    let location = try #require(captured.location)
    #expect(location.tabID == nil && location.waveVersion == nil)
    let encoded = try EventCodec.encode(waveEvent(location))
    let event = try EventCodec.decode(encoded)
    #expect(event.phase == .working && event.waveLocation == location)
    for raw in ["", "bad\nblock", String(repeating: "x", count: 257)] {
        let invalid = WaveLocationCapture.environment(["WAVETERM_BLOCKID": raw], observedAt: waveEpoch)
        #expect(invalid.waveBlockID == nil && invalid.location == nil)
    }
    let legacy = WaveLocationCapture.environment(["WAVETERM_BLOCKID": "block-1", "WAVETERM_TABID": waveTab.uuidString],
                                                observedAt: waveEpoch)
    #expect(legacy.waveBlockID == "block-1" && legacy.location == nil)
}

@Test func explicitGroupsRemainPartialUnlessTheirOwnTabAndVersionAreProvided() throws {
    let partial = try WaveLocationCapture.explicit(blockID: waveBlock.uuidString, observedAt: waveEpoch)
    #expect(partial.location?.tabID == nil && partial.location?.waveVersion == nil)
    #expect(partial.location?.source == .explicitArguments)
    let legacy = try WaveLocationCapture.explicit(blockID: "block-1", observedAt: waveEpoch)
    #expect(legacy.waveBlockID == "block-1" && legacy.location == nil)
    let full = try WaveLocationCapture.explicit(blockID: waveBlock.uuidString, tabID: waveTab.uuidString,
                                               waveVersion: "0.14.5", observedAt: waveEpoch)
    #expect(full.location?.tabID == waveTab && full.location?.observedAt == waveEpoch)
}

@Test func newExplicitFieldsRequireAFullBlockAndNeverEchoInvalidInput() throws {
    for block in [nil, "block-1", "this", "block:\(waveBlock.uuidString)"] as [String?] {
        #expect(throws: EventError.self) {
            try WaveLocationCapture.explicit(blockID: block, tabID: waveTab.uuidString, observedAt: waveEpoch)
        }
    }
    for (tab, version) in [("private-invalid-tab", "0.14.5"), (waveTab.uuidString, "private-invalid-version")] {
        do {
            _ = try WaveLocationCapture.explicit(blockID: waveBlock.uuidString, tabID: tab, waveVersion: version, observedAt: waveEpoch)
            Issue.record("Invalid explicit metadata was accepted")
        } catch { #expect(!error.localizedDescription.contains("private-invalid")) }
    }
}

@Test func locationAssessmentDistinguishesAbsentLegacyPartialAndUnreviewedVersions() {
    let policy = WaveLocationPolicy.standard
    #expect(policy.status(for: nil, at: waveEpoch).validity == .unknown)
    #expect(policy.status(for: nil, legacyBlockID: "block-1", at: waveEpoch).validity == .legacyOnly)
    #expect(policy.status(for: waveLocation(tab: nil), at: waveEpoch).validity == .partial)
    #expect(policy.status(for: waveLocation(version: nil), at: waveEpoch).validity == .partial)
    #expect(policy.status(for: waveLocation(version: "0.14.6"), at: waveEpoch).validity == .unreviewedWaveVersion)
    #expect(policy.status(for: waveLocation(version: "0.14.5-beta.1"), at: waveEpoch).validity == .unreviewedWaveVersion)
    #expect(policy.status(for: waveLocation(), at: waveEpoch).validity == .recent)
}

@Test func locationExpiresAtItsOwnDeadlineWithoutChangingWorkOrAttention() throws {
    var store = SessionStore()
    let location = waveLocation(at: waveEpoch.addingTimeInterval(-290))
    try store.receive([waveEvent(location)])
    let before = store.snapshot(at: waveEpoch.addingTimeInterval(9.999))
    #expect(before.sessions[0].waveLocation.validity == .recent)
    #expect(before.nextTransitionAt == waveEpoch.addingTimeInterval(10))
    let expired = store.snapshot(at: waveEpoch.addingTimeInterval(10))
    #expect(expired.sessions[0].waveLocation.validity == .stale && expired.workingCount == 1)
    #expect(expired.sessions[0].session == before.sessions[0].session)
    #expect(expired.sessions[0].attention == before.sessions[0].attention)
    #expect(expired.nextTransitionAt == waveEpoch.addingTimeInterval(300))
}

@Test func futureLocationClocksStayUnconfirmedWhileTheEventCanRemainFresh() throws {
    var store = SessionStore()
    try store.receive([waveEvent(waveLocation(at: waveEpoch.addingTimeInterval(30)))])
    let snapshot = store.snapshot(at: waveEpoch)
    #expect(snapshot.sessions[0].waveLocation.validity == .clockSkew && snapshot.workingCount == 1)
    #expect(snapshot.nextTransitionAt == waveEpoch.addingTimeInterval(300))
    let invalidClock = WaveLocationPolicy.standard.status(for: waveLocation(), at: Date(timeIntervalSince1970: .nan))
    #expect(invalidClock.validity == .clockSkew && invalidClock.nextTransitionAt == nil)
}

@Test func unconfirmedEventSourcesAlsoInvalidateLocationAndMatchTheWholeObservation() throws {
    let event = waveEvent(waveLocation())
    var store = SessionStore()
    try store.receive([event])
    let available = store.snapshot(at: waveEpoch, confirmedEvents: [event.id: event])
    #expect(available.sessions[0].waveLocation.validity == .recent)
    let missing = store.snapshot(at: waveEpoch, confirmedEvents: [:])
    #expect(missing.sessions[0].waveLocation.validity == .unconfirmedSource && missing.workingCount == 0)
    let unavailable = store.snapshot(at: waveEpoch, sourceIssue: .channelUnavailable)
    #expect(unavailable.sessions[0].waveLocation.validity == .unconfirmedSource)
    let changed = waveEvent(waveLocation(block: UUID()), id: event.id)
    let conflicting = store.snapshot(at: waveEpoch, confirmedEvents: [event.id: changed])
    #expect(conflicting.sessions[0].sourceIssue == .eventMissing)
    #expect(conflicting.sessions[0].waveLocation.validity == .unconfirmedSource)
}

@Test func ignoredDuplicateOlderAndRetiredEventsCannotRerouteTheCurrentSession() throws {
    var registry = SessionRegistry()
    let first = waveEvent(waveLocation(), turn: "one", kind: .turnStarted)
    try registry.apply(first)
    let next = waveEvent(waveLocation(block: UUID()), time: 1, turn: "two", kind: .turnStarted)
    try registry.apply(next)
    let attempts = [waveEvent(waveLocation(block: UUID()), time: 2, id: next.id, turn: "two"),
                    waveEvent(waveLocation(block: UUID()), time: 2, turn: "one", kind: .toolStarted),
                    waveEvent(waveLocation(block: UUID()), time: -1, turn: "two", kind: .toolStarted),
                    waveEvent(waveLocation(block: UUID()), time: 3, turn: "unbound", kind: .toolStarted)]
    for event in attempts {
        let decision = try registry.applyResult(event)
        #expect(decision != .applied)
        #expect(registry.sessions[0].waveLocation == next.waveLocation && registry.sessions[0].lastEventID == next.id)
    }
}

@Test func newerAppliedObservationWithoutLocationClearsEarlierMetadata() throws {
    var store = SessionStore()
    try store.receive([waveEvent(waveLocation()), waveEvent(nil, time: 1)])
    let snapshot = store.snapshot(at: waveEpoch.addingTimeInterval(2))
    #expect(snapshot.sessions[0].session.waveLocation == nil)
    #expect(snapshot.sessions[0].waveLocation.validity == .unknown && snapshot.workingCount == 1)
}

@Test func listingExtractsOnlyReviewedIDsAndDropsMetaAndUnverifiedWindow() throws {
    var row = listingRow()
    row["meta"] = ["cwd": "/fixture-private", "url": "fixture-private", "token": "fixture-private"]
    row["windowid"] = UUID().uuidString
    let output = try JSONSerialization.data(withJSONObject: [row])
    let location = try #require(parseListing(output))
    #expect(location.blockID == waveBlock && location.tabID == waveTab && location.workspaceID == waveWorkspace)
    #expect(location.windowID == nil && location.source == .blockListing && location.observedAt == waveEpoch)
    let text = String(decoding: try EventCodec.encode(waveEvent(location)), as: UTF8.self)
    #expect(!text.contains("fixture-private") && !text.contains("windowID") && !text.contains("meta"))
}

@Test func listingExitStatusWarningsAndNonJSONOutputsRemainUnknown() throws {
    let valid = try JSONSerialization.data(withJSONObject: [listingRow()])
    #expect(parseListing(valid, exitCode: 1) == nil)
    #expect(parseListing(valid, stderr: Data("Warning: partial results\n".utf8)) == nil)
    #expect(parseListing(valid, stderr: Data("\n".utf8)) == nil)
    for text in ["No blocks found\n", "[]", "null", "{}", "[", "[{}]", "", "[]\nWarning: partial"] {
        #expect(parseListing(Data(text.utf8)) == nil)
    }
}

@Test func listingRejectsDuplicateKeysIDsAndInvalidIdentityTypesAcrossTheWholeResult() throws {
    let row = listingRow()
    let duplicate = try JSONSerialization.data(withJSONObject: [row, row])
    #expect(parseListing(duplicate) == nil)
    let invalidValues: [Any] = [NSNull(), 7, "this"]
    for field in ["blockid", "tabid", "workspaceid"] {
        for invalid in invalidValues {
            var bad = row
            bad[field] = invalid
            let bytes = try JSONSerialization.data(withJSONObject: [row, bad])
            #expect(parseListing(bytes) == nil)
        }
    }
    let duplicateKey = Data("[{\"blockid\":\"\(waveBlock.uuidString)\",\"blockid\":\"\(waveBlock.uuidString)\",\"tabid\":\"\(waveTab.uuidString)\",\"workspaceid\":\"\(waveWorkspace.uuidString)\"}]".utf8)
    #expect(parseListing(duplicateKey) == nil)
}

@Test func listingRequiresConsistentRequestedAndHierarchicalScope() throws {
    let valid = try JSONSerialization.data(withJSONObject: [listingRow()])
    let matching = WaveBlockListing.location(stdout: valid, stderr: Data(), exitCode: 0, blockID: waveBlock,
                                            expectedTabID: waveTab, expectedWorkspaceID: waveWorkspace,
                                            waveVersion: "0.14.5", observedAt: waveEpoch)
    #expect(matching?.workspaceID == waveWorkspace)
    let mismatch = WaveBlockListing.location(stdout: valid, stderr: Data(), exitCode: 0, blockID: waveBlock,
                                            expectedTabID: UUID(), waveVersion: "0.14.5", observedAt: waveEpoch)
    #expect(mismatch == nil)
    var other = listingRow(block: UUID())
    other["workspaceid"] = UUID().uuidString
    let conflictingTab = try JSONSerialization.data(withJSONObject: [listingRow(), other])
    #expect(parseListing(conflictingTab) == nil)
    let missing = WaveBlockListing.location(stdout: valid, stderr: Data(), exitCode: 0, blockID: UUID(),
                                           waveVersion: "0.14.5", observedAt: waveEpoch)
    #expect(missing == nil)
}

@Test func listingBoundsBytesRowsVersionsAndObservationClocks() throws {
    #expect(parseListing(Data(repeating: 0x20, count: WaveBlockListing.maximumBytes + 1)) == nil)
    let tooManyRows = (0...WaveBlockListing.maximumRows).map { _ in listingRow(block: UUID()) }
    let bytes = try JSONSerialization.data(withJSONObject: tooManyRows)
    #expect(bytes.count < WaveBlockListing.maximumBytes)
    #expect(parseListing(bytes) == nil)
    let valid = try JSONSerialization.data(withJSONObject: [listingRow()])
    #expect(parseListing(valid, version: "0.14.6") == nil)
    let invalidTime = WaveBlockListing.location(stdout: valid, stderr: Data(), exitCode: 0, blockID: waveBlock,
                                               waveVersion: "0.14.5", observedAt: Date(timeIntervalSince1970: .infinity))
    #expect(invalidTime == nil)
}

@Test func codexAdaptersPropagateLocationWithoutRenewingItsObservationClock() throws {
    let location = waveLocation(at: waveEpoch.addingTimeInterval(-10))
    let hook = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"session","turn_id":"turn","cwd":"/synthetic/project","prompt":"fixture-private"}"#.utf8)
    let observed = try CodexHookAdapter.event(from: hook, receivedAt: waveEpoch, waveBlockID: waveBlock.uuidString, waveLocation: location)
    #expect(observed?.waveLocation == location && observed?.occurredAt == waveEpoch)
    let payload = Data(#"{"type":"agent-turn-complete","thread-id":"session","turn-id":"turn","cwd":"/synthetic/project","last-assistant-message":"fixture-private"}"#.utf8)
    let notification = try JSONDecoder().decode(CodexNotification.self, from: payload)
    let event = try notification.event(at: waveEpoch, waveBlockID: waveBlock.uuidString, waveLocation: location)
    #expect(event.waveLocation == location && event.occurredAt == waveEpoch)
    let text = String(decoding: try EventCodec.encode(event), as: UTF8.self)
    #expect(!text.contains("fixture-private") && !text.contains("/synthetic"))
}

private func waveLocation(block: UUID = waveBlock, tab: UUID? = waveTab, version: String? = "0.14.5",
                          at: Date = waveEpoch) -> WaveLocation {
    WaveLocation(blockID: block, tabID: tab, waveVersion: version, observedAt: at, source: .environment)
}

private func waveEvent(_ location: WaveLocation?, time: TimeInterval = 0, id: UUID = UUID(), legacy: String? = nil,
                       turn: String? = nil, kind: EventKind = .status) -> AgentEvent {
    let at = waveEpoch.addingTimeInterval(time)
    return AgentEvent(version: 2, id: id, sessionID: "session", projectName: "project", phase: kind.expectedPhase ?? .working,
                      occurredAt: at, waveBlockID: legacy ?? location?.blockID.uuidString, waveLocation: location,
                      context: EventContext(source: kind == .status ? .manual : .codexHook, kind: kind, receivedAt: at,
                                            turnID: turn, toolName: kind == .toolStarted ? "shell" : nil,
                                            toolUseID: kind == .toolStarted ? "tool" : nil))
}

private func listingRow(block: UUID = waveBlock) -> [String: Any] {
    ["blockid": block.uuidString, "tabid": waveTab.uuidString, "workspaceid": waveWorkspace.uuidString, "view": "term"]
}

private func parseListing(_ output: Data, stderr: Data = Data(), exitCode: Int32 = 0,
                          version: String = "0.14.5") -> WaveLocation? {
    WaveBlockListing.location(stdout: output, stderr: stderr, exitCode: exitCode, blockID: waveBlock,
                              waveVersion: version, observedAt: waveEpoch)
}
