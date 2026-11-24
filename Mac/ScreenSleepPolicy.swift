enum ScreenSleepPolicy {
    static func shouldTearDown(activeSessions: Int, screenSlept: Bool) -> Bool {
        activeSessions > 0 && screenSlept
    }
}
