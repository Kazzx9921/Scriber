import XCTest

final class AudioPreferencesTests: XCTestCase {
    func testDefaultsWhenNothingIsStored() {
        let prefs = AudioPreferences.load(from: makeTestDefaults(self))
        XCTAssertNil(prefs.inputDeviceUID)
        XCTAssertEqual(prefs.startCue.effectiveSource, .standard)
        XCTAssertEqual(prefs.stopCue.effectiveSource, .standard)
        XCTAssertEqual(prefs.cueVolume, AudioPreferences.defaultCueVolume)
        XCTAssertFalse(prefs.muteOutput)
        XCTAssertFalse(prefs.pauseMedia)
        XCTAssertEqual(prefs.resumeDelay, 1)
    }

    func testRoundTrip() {
        let defaults = makeTestDefaults(self)
        var prefs = AudioPreferences()
        prefs.inputDeviceUID = "AppleUSBAudioEngine:Yeti:1"
        prefs.inputDeviceName = "Yeti"
        prefs.startCue = CueSetting(source: .none)
        prefs.stopCue = CueSetting(source: .custom, customFile: "stop-1.wav", customName: "ding")
        prefs.cueVolume = 0.3
        prefs.muteOutput = true
        prefs.pauseMedia = true
        prefs.resumeDelay = 3
        prefs.save(to: defaults)
        XCTAssertEqual(AudioPreferences.load(from: defaults), prefs)

        // Back to 跟隨系統 clears the stored device.
        prefs.inputDeviceUID = nil
        prefs.inputDeviceName = nil
        prefs.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: AudioPreferences.Key.inputDeviceUID))
        XCTAssertEqual(AudioPreferences.load(from: defaults), prefs)
    }

    func testOutOfRangeValuesAreClampedOrIgnored() {
        let defaults = makeTestDefaults(self)
        defaults.set(7.0, forKey: AudioPreferences.Key.cueVolume)
        defaults.set(4.0, forKey: AudioPreferences.Key.resumeDelay) // not a choice
        defaults.set("bogus", forKey: AudioPreferences.Key.cueSource(.start))
        let prefs = AudioPreferences.load(from: defaults)
        XCTAssertEqual(prefs.cueVolume, 1)
        XCTAssertEqual(prefs.resumeDelay, 1)
        XCTAssertEqual(prefs.startCue.source, .standard)
    }

    func testCustomWithoutFileBehavesLikeDefault() {
        XCTAssertEqual(CueSetting(source: .custom).effectiveSource, .standard)
        XCTAssertEqual(CueSetting(source: .custom, customFile: "a.wav").effectiveSource, .custom)
        XCTAssertEqual(CueSetting(source: .none, customFile: "a.wav").effectiveSource, .none)
    }

    // MARK: Migration of the old single switch

    func testOldSwitchOffMeansBothCuesNone() {
        let defaults = makeTestDefaults(self)
        defaults.set(false, forKey: AudioPreferences.Key.legacyCues)
        XCTAssertNotNil(AudioPreferences.migrate(defaults))
        let prefs = AudioPreferences.load(from: defaults)
        XCTAssertEqual(prefs.startCue.effectiveSource, .none)
        XCTAssertEqual(prefs.stopCue.effectiveSource, .none)
        XCTAssertNil(defaults.object(forKey: AudioPreferences.Key.legacyCues), "runs once")
        XCTAssertNil(AudioPreferences.migrate(defaults))
    }

    func testOldSwitchOnKeepsDefaults() {
        let defaults = makeTestDefaults(self)
        defaults.set(true, forKey: AudioPreferences.Key.legacyCues)
        AudioPreferences.migrate(defaults)
        let prefs = AudioPreferences.load(from: defaults)
        XCTAssertEqual(prefs.startCue.effectiveSource, .standard)
        XCTAssertEqual(prefs.stopCue.effectiveSource, .standard)
        XCTAssertNil(defaults.object(forKey: AudioPreferences.Key.legacyCues))
    }

    func testPerCueChoicesAlreadyStoredWin() {
        let defaults = makeTestDefaults(self)
        defaults.set(CueSource.custom.rawValue, forKey: AudioPreferences.Key.cueSource(.start))
        defaults.set("start-x.wav", forKey: AudioPreferences.Key.cueFile(.start))
        defaults.set(false, forKey: AudioPreferences.Key.legacyCues)
        AudioPreferences.migrate(defaults)
        let prefs = AudioPreferences.load(from: defaults)
        XCTAssertEqual(prefs.startCue.effectiveSource, .custom)
        XCTAssertEqual(prefs.stopCue.effectiveSource, .none)
    }

    func testNothingToMigrate() {
        XCTAssertNil(AudioPreferences.migrate(makeTestDefaults(self)))
    }

    // MARK: Log tokens

    func testLogNeverContainsTheDeviceNameOrUID() {
        var prefs = AudioPreferences()
        prefs.inputDeviceUID = "00-11-22-33-44-55:input"
        prefs.inputDeviceName = "Kazen 的 AirPods"
        let line = prefs.logDescription
        XCTAssertFalse(line.contains("AirPods"))
        XCTAssertFalse(line.contains("00-11-22"))
        XCTAssertTrue(line.contains(AudioLog.tag("00-11-22-33-44-55:input")))
    }

    func testDeviceTagIsStableAndShort() {
        XCTAssertEqual(AudioLog.tag("BuiltInMicrophoneDevice"), AudioLog.tag("BuiltInMicrophoneDevice"))
        XCTAssertNotEqual(AudioLog.tag("a"), AudioLog.tag("b"))
        XCTAssertEqual(AudioLog.tag("x").count, "dev#".count + 6)
    }

    func testStatusFormatting() {
        XCTAssertEqual(AudioLog.status(0), "0")
        XCTAssertEqual(AudioLog.status(-50), "-50")
        XCTAssertEqual(AudioLog.status(Int32(bitPattern: 0x7768_6174)), "2003329396('what')")
    }
}
