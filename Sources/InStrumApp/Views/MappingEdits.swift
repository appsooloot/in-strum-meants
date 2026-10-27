import InStrumCore

/// Pure edits behind the mapping editor.
enum MappingEdits {
    /// All roles, then the theme's continuous settings.
    static func targets(for themeID: String) -> [Target] {
        Role.allCases.map { Target.role($0) } +
            ThemeRegistry.parameters(for: themeID).filter { $0.range != nil }.map { Target.param($0.id) }
    }

    static func groups(_ map: ReactionMap) -> [(family: InputFamily, links: [Link])] {
        InputFamily.allCases.compactMap { f in
            let links = map.links.filter { $0.input.family == f }
            return links.isEmpty ? nil : (f, links)
        }
    }

    static func inputs(seen: [InputID]) -> [InputID] {
        var out = InputID.standard
        for i in seen.sorted(by: { $0.rawValue < $1.rawValue }) where !out.contains(i) { out.append(i) }
        return out
    }

    static func edit(_ map: ReactionMap, link id: Link.ID, _ change: (inout Link) -> Void) -> ReactionMap {
        var m = map
        if let i = m.links.firstIndex(where: { $0.id == id }) { change(&m.links[i]) }
        return m
    }

    static func retarget(_ map: ReactionMap, link id: Link.ID, to target: Target) -> ReactionMap {
        edit(map, link: id) { $0.target = target }
    }

    static func addLink(_ map: ReactionMap) -> ReactionMap {
        var m = map
        m.links.append(Link(input: .velocity, target: .role(.energy), amount: 0.5))
        return m
    }

    static func remove(_ map: ReactionMap, link id: Link.ID) -> ReactionMap {
        var m = map
        m.links.removeAll { $0.id == id }
        return m
    }

    static func targetName(_ t: Target, themeID: String) -> String {
        switch t {
        case let .role(r): return r.displayName
        case let .param(id): return ThemeRegistry.parameters(for: themeID).first { $0.id == id }?.name ?? id
        }
    }
}
