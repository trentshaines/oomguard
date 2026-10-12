import Testing
@testable import OOMGuardCore

@Test func parsesTablesArraysAndComments() throws {
    let toml = try parseTOML("""
    # top comment
    dry_run = true
    interval_seconds = 1.5

    [victim]
    min_size_gb = 4          # trailing comment
    prefer = ["python.*dataset", "node # not a comment"]
    avoid = [
      "Docker",   # docker last
      "OrbStack",
    ]
    """)
    #expect(toml["dry_run"] == .bool(true))
    #expect(toml["interval_seconds"] == .float(1.5))
    #expect(toml["victim.min_size_gb"] == .integer(4))
    #expect(toml["victim.prefer"] == .array([.string("python.*dataset"), .string("node # not a comment")]))
    #expect(toml["victim.avoid"] == .array([.string("Docker"), .string("OrbStack")]))
}

@Test func emptyFileGivesDefaults() throws {
    #expect(try Config(toml: parseTOML("")) == Config())
}

@Test func configReadsEverySection() throws {
    let config = try Config(toml: parseTOML("""
    [trigger]
    kill_occupancy = 0.8
    kill_eta_seconds = 30
    pressure_critical_seconds = 0
    warn_headroom_gb = 16
    [victim]
    min_size_gb = 3
    never_extra = ["^Xcode$"]
    [kill]
    term_seconds = 1
    [agents]
    names = ["claude"]
    [notify]
    enabled = false
    [recorder]
    enabled = false
    max_mb = 10
    [guard]
    jetsam_band = 0
    [hooks]
    pre_kill = "echo $OOMGUARD_PGID"
    """))
    #expect(config.killOccupancy == 0.8)
    #expect(config.killEtaSeconds == 30)
    #expect(config.pressureCriticalSeconds == 0)
    #expect(config.warnHeadroomGB == 16)
    #expect(config.minSizeGB == 3)
    #expect(config.never == Config.defaultNever + ["^Xcode$"])
    #expect(config.termSeconds == 1)
    #expect(config.agentNames == ["claude"])
    #expect(config.notifications == false)
    #expect(config.recorderEnabled == false)
    #expect(config.recorderMaxMB == 10)
    #expect(config.jetsamBand == 0)
    #expect(config.preKill == "echo $OOMGUARD_PGID")
}

@Test func rejectsUnknownKeysBadTypesAndBadRegexes() {
    #expect(throws: ConfigError.self) { try Config(toml: parseTOML("[trigger]\nkill_ocupancy = 0.8")) }
    #expect(throws: ConfigError.self) { try Config(toml: parseTOML("[trigger]\nkill_occupancy = 85")) }
    #expect(throws: ConfigError.self) { try Config(toml: parseTOML("[guard]\njetsam_band = 5")) }
    #expect(throws: ConfigError.self) { try Config(toml: parseTOML("dry_run = \"yes\"")) }
    #expect(throws: ConfigError.self) { try Config(toml: parseTOML("[victim]\nprefer = [\"(unclosed\"]")) }
    #expect(throws: TOMLError.self) { try parseTOML("dry_run = true\ndry_run = false") }
    #expect(throws: TOMLError.self) { try parseTOML("name = \"unterminated") }
}
