import Foundation
import XCTest
@testable import MacRelayCore

final class IRCMessageTests: XCTestCase {
    func testSyncedServerProfilesRoundTrip() throws {
        var profile = ServerConfiguration()
        profile.name = "ZNC"
        profile.host = "znc.example.net"
        let payload = SyncedServerProfiles(profiles: [profile], selectedProfileID: profile.id)

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SyncedServerProfiles.self, from: encoded)

        XCTAssertEqual(decoded.profiles, [profile])
        XCTAssertEqual(decoded.selectedProfileID, profile.id)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testParsesServerTimePlaybackMessage() throws {
        let raw = "@time=2026-08-09T09:15:31.125Z;msgid=abc123 :Kurtern!user@example PRIVMSG #norge :Hei fra ZNC"
        let message = try XCTUnwrap(IRCMessage.parse(raw))

        XCTAssertEqual(message.command, "PRIVMSG")
        XCTAssertEqual(message.nickname, "Kurtern")
        XCTAssertEqual(message.parameters, ["#norge", "Hei fra ZNC"])
        XCTAssertEqual(message.tags["msgid"], "abc123")
        XCTAssertNotNil(message.serverTimestamp)
    }

    func testParsesOrdinaryMessageWithoutTags() throws {
        let message = try XCTUnwrap(IRCMessage.parse(":nick!user@host PRIVMSG MacRelayUser :Privat melding"))

        XCTAssertEqual(message.nickname, "nick")
        XCTAssertEqual(message.parameters, ["MacRelayUser", "Privat melding"])
        XCTAssertNil(message.serverTimestamp)
    }

    func testConfigurationKeepsSafeDefaultsWhenDecodingOlderProfile() throws {
        let profile = try JSONDecoder().decode(
            ServerConfiguration.self,
            from: Data(#"{"host":"irc.example.net","nickname":"tester"}"#.utf8)
        )

        XCTAssertEqual(profile.host, "irc.example.net")
        XCTAssertEqual(profile.nickname, "tester")
        XCTAssertTrue(profile.useTLS)
        XCTAssertEqual(profile.port, 6697)
    }
}
