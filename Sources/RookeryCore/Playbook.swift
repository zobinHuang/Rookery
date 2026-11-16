import Foundation

/// A skill a playbook loads, at the version it holds it to.
public struct PlaybookPin: Equatable, Hashable, Identifiable, Sendable {
    /// What a pin is when it follows the skill's tracked ref.
    public static let latest = "latest"

    public let skillId: String
    /// `latest`, a branch or tag, or a commit.
    public var pin: String

    public var id: String {
        skillId
    }

    public init(skillId: String, pin: String = PlaybookPin.latest) {
        self.skillId = skillId
        self.pin = pin
    }

    /// The pins a playbook resource holds.
    public static func pins(of playbook: FleetResource) -> [PlaybookPin] {
        guard case .array(let listValues) = playbook.mapAttributes["skills"] else {
            return []
        }
        return listValues.compactMap { value in
            if let skillId = value.stringValue {
                return PlaybookPin(skillId: skillId)
            }
            guard let skillId = value["skill_id"]?.stringValue else {
                return nil
            }
            return PlaybookPin(skillId: skillId, pin: value["pin"]?.stringValue ?? latest)
        }
    }

    /// The pin as roost takes it in a playbook's `skills`.
    public var payload: JSONValue {
        pin == Self.latest ? .string(skillId) : .object(["skill_id": .string(skillId), "pin": .string(pin)])
    }
}

/// A playbook's steps name the skills a step uses with `@`, by the skill's id or its name with spaces as
/// dashes; saving the playbook pins every skill its steps name.
public enum PlaybookSteps {
    private static var mentionPattern: Regex<(Substring, Substring)> {
        #/@([A-Za-z0-9][A-Za-z0-9._\-/]*)/#
    }

    /// The registered skills a playbook's steps name, in the order they first appear.
    ///
    /// - Parameters:
    ///   - prompt: the playbook's steps
    ///   - listSkills: the skills roost has registered
    public static func skillIds(namedIn prompt: String, among listSkills: [FleetResource]) -> [String] {
        var listIds: [String] = []
        for match in prompt.matches(of: mentionPattern) {
            let token = String(match.1).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)/"))
            let skill = listSkills.first { skill in
                skill.id.lowercased() == token || skill.name.lowercased().replacingOccurrences(of: " ", with: "-") == token
            }
            if let skill, !listIds.contains(skill.id) {
                listIds.append(skill.id)
            }
        }
        return listIds
    }

    /// The pins a playbook should hold: those it holds, then one for each newly named skill.
    public static func pins(_ listPins: [PlaybookPin], adding listNamedIds: [String]) -> [PlaybookPin] {
        let setHeld = Set(listPins.map(\.skillId))
        return listPins + listNamedIds.filter { !setHeld.contains($0) }.map { PlaybookPin(skillId: $0) }
    }
}
