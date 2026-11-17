import Testing
@testable import TideIslandCore

@Test func systemStatusStartsUnknownWithoutClaimingVisibleActivity() {
    let status = SystemStatusProjection()
    #expect(status.notices.first?.id == "activity.checking" && status.attentionCount == 0)
    #expect(status.notices.contains { $0.id == "reminder.off" })
}

@Test func systemStatusKeepsMenuAndSessionFallbackWhenAPIIsUnavailable() throws {
    let notice = try #require(SystemStatusProjection(activity: .unavailable).notices.first)
    #expect(notice.level == .attention && notice.action == .none)
    #expect(notice.detail.contains("菜单栏") && notice.detail.contains("会话列表"))
}

@Test func systemStatusDoesNotConfuseActivityAuthorizationWithNotificationPermission() {
    let status = SystemStatusProjection(activity: .disabled, hasConfirmedSource: true, remindersEnabled: true, notificationAuthorization: .allowed)
    #expect(status.notices.contains { $0.id == "activity.disabled" && $0.level == .attention })
    #expect(status.notices.contains { $0.id == "reminder.allowed" && $0.level == .information })
}

@Test func systemStatusAllowedDoesNotProveVisibleIslandOrBanner() throws {
    let status = SystemStatusProjection(activity: .allowed, hasConfirmedSource: true, remindersEnabled: true, notificationAuthorization: .allowed)
    let activity = try #require(status.notices.first { $0.id == "activity.allowed" })
    let reminder = try #require(status.notices.first { $0.id == "reminder.allowed" })
    #expect(activity.detail.contains("系统决定") && reminder.detail.contains("系统可能"))
    #expect(status.attentionCount == 0)
}

@Test func systemStatusRequiresConfirmedSourceDespiteBothPermissionsBeingAllowed() {
    let status = SystemStatusProjection(activity: .allowed, remindersEnabled: true, notificationAuthorization: .allowed)
    #expect(status.notices.contains { $0.id == "activity.source" && $0.action == .checkAgain })
    #expect(status.notices.contains { $0.id == "reminder.source" && $0.detail.contains("不补发") })
    #expect(status.attentionCount == 2)
}

@Test func systemStatusKeepsCleanupFailureVisibleEvenWhenActivitiesAreDisabled() {
    let status = SystemStatusProjection(activity: .disabled, activityProblem: .endFailed)
    #expect(status.notices.contains { $0.id == "activity.disabled" })
    #expect(status.notices.contains { $0.id == "activity.error.endFailed" && $0.detail.contains("可能仍有") })
    #expect(status.attentionCount == 2)
}

@Test func systemStatusDoesNotClaimCurrentActivitySucceededAfterAnOldUpdateFailure() {
    let status = SystemStatusProjection(activity: .allowed, hasConfirmedSource: true, activityProblem: .updateFailed)
    #expect(status.activitySummary == "上次活动更新失败")
    #expect(status.notices.contains { $0.id == "activity.allowed" })
    #expect(status.notices.contains { $0.id == "activity.error.updateFailed" && $0.detail.contains("较早状态") })
}

@Test func systemStatusAuthorizationCanRecoverWithoutRewritingHistoricalFailure() {
    let old = SystemStatusProjection(activity: .disabled, activityProblem: .disabled)
    let current = SystemStatusProjection(activity: .allowed, hasConfirmedSource: true, activityProblem: .disabled)
    let recovered = SystemStatusProjection(activity: .allowed, hasConfirmedSource: true)
    #expect(old.notices.filter { $0.id.hasPrefix("activity.") }.count == 1)
    #expect(current.activitySummary.contains("上次"))
    #expect(recovered.activitySummary == "系统允许实时活动" && recovered.attentionCount == 0)
}

@Test func systemStatusForegroundRequirementOffersActivationWithoutChangingAuthorization() throws {
    let status = SystemStatusProjection(activity: .allowed, hasConfirmedSource: true, activityProblem: .foregroundRequired)
    let notice = try #require(status.notices.first { $0.id == "activity.error.foregroundRequired" })
    #expect(notice.action == .openSessions && notice.level == .attention)
    #expect(notice.detail.contains("打开会话窗口") && status.activitySummary == notice.title)
    #expect(status.notices.contains { $0.id == "activity.allowed" })
    #expect(!status.notices.contains { $0.id == "activity.disabled" })
}

@Test func systemStatusNotificationNotRequestedAndDeniedHaveDistinctRecoveryStates() {
    let missing = SystemStatusProjection(remindersEnabled: true, notificationAuthorization: .notRequested, reminderProblem: .authorizationNotRequested)
    let denied = SystemStatusProjection(remindersEnabled: true, notificationAuthorization: .denied, reminderProblem: .permissionDenied)
    #expect(missing.notices.contains { $0.id == "reminder.notRequested" && $0.action == .reminderSettings })
    #expect(denied.notices.contains { $0.id == "reminder.denied" && $0.action == .reminderSettings })
    #expect(missing.notices.filter { $0.id.hasPrefix("reminder.") }.count == 1)
    #expect(denied.notices.filter { $0.id.hasPrefix("reminder.") }.count == 1)
}

@Test func systemStatusTurningRemindersOffDoesNotOfferOldFailureReplay() {
    let status = SystemStatusProjection(notificationAuthorization: .denied, reminderProblem: .deliveryFailed)
    #expect(status.notices.filter { $0.id.hasPrefix("reminder.") }.map(\.id) == ["reminder.off"])
    #expect(status.notices.first { $0.id == "reminder.off" }?.level == .information)
}

@Test func systemStatusUncertainNotificationKeepsNoRetryDeliveryContract() throws {
    let status = SystemStatusProjection(hasConfirmedSource: true, remindersEnabled: true, notificationAuthorization: .allowed, reminderProblem: .deliveryFailed)
    let notice = try #require(status.notices.first { $0.id == "reminder.error.deliveryFailed" })
    #expect(notice.detail.contains("可能已经提交") && notice.detail.contains("不会自动重发"))
    #expect(notice.action == .checkAgain)
}

@Test func systemStatusSimultaneousProblemsRemainIndependentAndHaveUniqueStableIDs() {
    let status = SystemStatusProjection(activity: .allowed, activityProblem: .invalidInventory, remindersEnabled: true,
                                        notificationAuthorization: .denied, reminderProblem: .invalidSnapshot, login: .requiresApproval)
    #expect(status.attentionCount == 5 && Set(status.notices.map(\.id)).count == status.notices.count)
    #expect(status.notices.contains { $0.id == "login.approval" && $0.action == .loginSettings })
    #expect(status.notices.contains { $0.id == "activity.error.invalidInventory" && $0.detail.contains("未删除") })
}

@Test func systemStatusLoginIntentDoesNotSubstituteForSystemApproval() {
    #expect(LoginItemState.requiresApproval.isRequested && LoginItemState.enabled.isRequested)
    #expect(!LoginItemState.unavailable.isRequested && !LoginItemState.disabled.isRequested)
    #expect(SystemStatusProjection(login: .enabled).notices.allSatisfy { !$0.id.hasPrefix("login.") })
    #expect(SystemStatusProjection(login: .unavailable).notices.contains { $0.id == "login.unavailable" && $0.action == .none })
}

@Test func systemStatusAllActivityFailuresKeepTheirCodeAndRecoveryWithoutRawErrors() {
    let problems: [IslandActivityError] = [.invalidClock, .invalidContent, .contentBudgetExceeded, .disabled, .busy, .invalidActivityID,
        .requestFailed, .foregroundRequired, .updateFailed, .endFailed, .schedulingFailed, .cancelled, .inventoryFailed, .invalidInventory, .stopped]
    for problem in problems {
        let status = SystemStatusProjection(activity: .allowed, hasConfirmedSource: true, activityProblem: problem)
        let expectedAction: SystemStatusAction = problem == .foregroundRequired ? .openSessions : .checkAgain
        #expect(status.notices.contains { $0.id == "activity.error.\(problem.rawValue)" && $0.action == expectedAction })
        #expect(status.attentionCount == 1)
    }
}

@Test func systemStatusAllReminderFailuresRemainVisibleAlongsideCurrentAuthorization() {
    let problems: [SessionReminderProblem] = [.invalidClock, .invalidSnapshot, .capacityExceeded, .authorizationNotRequested, .permissionDenied, .deliveryFailed]
    for problem in problems {
        let status = SystemStatusProjection(activity: .allowed, hasConfirmedSource: true, remindersEnabled: true,
                                            notificationAuthorization: .allowed, reminderProblem: problem)
        #expect(status.notices.contains { $0.id == "reminder.error.\(problem.rawValue)" })
        #expect(status.notices.contains { $0.id == "reminder.allowed" } && status.attentionCount == 1)
    }
}
