import Foundation

/// The brand a workspace works for: its `brand` in `simbia-workspace.json`. Outside a workspace, the machine's
/// ~/Library/Application Support/Simbia Captions/Brand.json, e.g. `{"name": "Acme", "key": "acme"}`.
public struct Brand: Codable, Equatable, Sendable {
    /// Spelt this way in every caption (the dictionary's first word); "" = none.
    public var name = ""
    /// How the footage index names the product in its tags: "applying_<key>", "<key>_tube_to_camera", `segment.product`.
    public var key = "product"
    /// A track of the music library whose loudness a new bed is set to; nil = no house level.
    public var houseMusic: String?

    public init(name: String = "", key: String = "product", houseMusic: String? = nil) {
        self.name = name; self.key = key; self.houseMusic = houseMusic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "product"
        houseMusic = try c.decodeIfPresent(String.self, forKey: .houseMusic)
    }

    private enum CodingKeys: String, CodingKey { case name, key, houseMusic }

    /// The machine's own, for projects outside any workspace.
    public static let machine: Brand = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Simbia Captions/Brand.json")
        guard let data = try? Data(contentsOf: url), let brand = try? JSONDecoder().decode(Brand.self, from: data) else { return Brand() }
        return brand
    }()

    /// The open workspace's brand, else the machine's.
    public static var current: Brand { Workspace.active?.settings.brand ?? machine }

    /// The index's tag for the product being put on, and for it held up to the camera.
    public var applyingTag: String { "applying_" + key }
    public var tubeTag: String { key + "_tube_to_camera" }
}
