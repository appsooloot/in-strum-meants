import XCTest
@testable import InStrumApp
@testable import InStrumCore

final class MappingEditorTests: XCTestCase {
    func testTargetsIncludeAllRolesThenThemeSliders() {
        let targets = MappingEdits.targets(for: ButterflyGardenModel.id)
        XCTAssertEqual(Array(targets.prefix(Role.allCases.count)), Role.allCases.map { Target.role($0) })
        XCTAssertTrue(targets.contains(.param("wings.iridescence")))
        XCTAssertFalse(targets.contains(.param("time")))   // choices aren't continuous targets
    }
    func testGroupsFollowFamilyOrder() {
        let groups = MappingEdits.groups(ReactionPresets.expressivePianist)
        XCTAssertEqual(groups.map(\.family), InputFamily.allCases.filter { f in groups.contains { $0.family == f } })
        XCTAssertEqual(groups.reduce(0) { $0 + $1.links.count }, ReactionPresets.expressivePianist.links.count)
    }
    func testRetargetKeepsEverythingElse() {
        let map = ReactionPresets.minimal
        let id = map.links[0].id
        let edited = MappingEdits.retarget(map, link: id, to: .role(.colorShift))
        XCTAssertEqual(edited.links[0].target, .role(.colorShift))
        XCTAssertEqual(edited.links[0].input, map.links[0].input)
        XCTAssertEqual(Array(edited.links.dropFirst()), Array(map.links.dropFirst()))
    }
    func testAddAndRemoveLink() {
        var map = ReactionPresets.minimal
        map = MappingEdits.addLink(map)
        XCTAssertEqual(map.links.count, ReactionPresets.minimal.links.count + 1)
        map = MappingEdits.remove(map, link: map.links.last!.id)
        XCTAssertEqual(map, ReactionPresets.minimal)
    }
    func testInputsIncludeStandardAndSeen() {
        let inputs = MappingEdits.inputs(seen: [.cc(21), .dial(7)])
        XCTAssertTrue(inputs.contains(.velocity))
        XCTAssertTrue(inputs.contains(.beat))
        XCTAssertTrue(inputs.contains(.cc(21)))
        XCTAssertTrue(inputs.contains(.dial(7)))
        XCTAssertEqual(Set(inputs).count, inputs.count)
    }
    func testInputNamesAreFriendly() {
        XCTAssertEqual(InputID.velocity.displayName, "How hard (velocity)")
        XCTAssertEqual(InputID.cc(21).displayName, "Knob / fader CC 21")
    }
}
