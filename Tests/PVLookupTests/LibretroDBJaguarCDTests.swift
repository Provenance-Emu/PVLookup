import Testing
import Foundation
@testable import libretrodb
import PVSystems
import PVLookupTypes
import PVLookupTestSupport

/// Jaguar CD is platform 120 in the full libretrodb, appended from libretro-database's
/// `Atari - Jaguar CD` dat by `Tools/libretrodb/add_platform.py`. The dat hashes the first
/// track of a disc's second session, and only some games carry a serial.
@Suite("libretrodb Jaguar CD platform")
struct LibretroDBJaguarCDTests {
    let db: libretrodb

    init() async throws {
        TestDatabases.configure()
        self.db = try await libretrodb()
    }

    @Test("A session 2 track hash finds its game on Jaguar CD")
    func trackHash() async throws {
        let game = try #require(try await db.searchROM(byMD5: Hash.battleMorph))
        #expect(game.systemID == .AtariJaguarCD)
        #expect(game.romFileName == "Battle Morph (USA) (Track 02).bin")
        #expect(game.region == "USA")
    }

    // The Songbird reissue has the original's serial, so its row is keyed by its hash.
    @Test("A reissue that shares a serial is still its own game")
    func reissueSharingASerial() async throws {
        let game = try #require(try await db.searchROM(byMD5: Hash.battleMorphSongbird))
        #expect(game.systemID == .AtariJaguarCD)
        #expect(game.romFileName == "Battle Morph (USA) (Songbird) (Track 02).bin")
        #expect(game.serial == nil)
    }

    @Test("A game with no serial is found by hash")
    func gameWithoutSerial() async throws {
        let game = try #require(try await db.searchROM(byMD5: Hash.dragonsLair))
        #expect(game.systemID == .AtariJaguarCD)
        #expect(game.romFileName == "Dragon's Lair (USA) (Track 2).bin")
        #expect(game.serial == nil)
    }

    @Test("A hash names the system")
    func systemFromHash() async throws {
        #expect(try await db.systemIdentifier(forRomMD5: Hash.battleMorph, or: nil) == .AtariJaguarCD)
    }

    @Test("A file name search stays on Jaguar CD")
    func fileName() async throws {
        let games = try #require(try await db.searchDatabase(usingFilename: "Battle Morph (USA)", systemID: .AtariJaguarCD))
        #expect(games.map(\.romFileName) == [
            "Battle Morph (USA) (Track 02).bin",
            "Battle Morph (USA) (Songbird) (Track 02).bin"
        ])
        #expect(games.allSatisfy { $0.systemID == .AtariJaguarCD })
    }

    @Test("A serial finds the disc")
    func serial() async throws {
        let game = try #require(try await db.searchROM(bySerial: "J9017E", systemID: .AtariJaguarCD))
        #expect(game.systemID == .AtariJaguarCD)
        #expect(game.serial == "J9017E")
        #expect(game.romFileName == "Battle Morph (USA) (Track 02).bin")
    }

    // Iron Soldier 2's cartridge and disc share the serial JA910. The cartridge had it first.
    @Test("A serial the cartridge already had still finds only the cartridge")
    func serialSharedWithCartridge() async throws {
        let cartridge = try #require(try await db.searchROM(bySerial: "JA910", systemID: .AtariJaguar))
        #expect(cartridge.systemID == .AtariJaguar)
        #expect(cartridge.romFileName == "Iron Soldier 2 (USA, Europe).j64")
        let disc = try #require(try await db.searchROM(byMD5: Hash.ironSoldier2))
        #expect(disc.systemID == .AtariJaguarCD)
        #expect(disc.romFileName == "Iron Soldier 2 (USA) (Songbird) (Track 12).bin")
    }

    @Test("Jaguar cartridges are still on their own platform")
    func cartridgesUnchanged() async throws {
        let games = try #require(try await db.searchDatabase(usingFilename: "Iron Soldier 2", systemID: .AtariJaguar))
        #expect(games.map(\.romFileName) == ["Iron Soldier 2 (USA, Europe).j64"])
    }

    private enum Hash {
        static let battleMorph = "CBA15B005C4B128084FBF48B3F2F2683"
        static let battleMorphSongbird = "3870D0B5AB3FAD81DB05CC832F6EBADF"
        static let dragonsLair = "B4EE6F7BDDB9FFF4BDB742EFD26FD372"
        static let ironSoldier2 = "3C4334206B62A7A198D21159D120F30A"
    }
}
