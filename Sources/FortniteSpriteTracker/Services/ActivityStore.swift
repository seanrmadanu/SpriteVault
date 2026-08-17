import Foundation

@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var events: [ActivityEvent] = []

    private let saveURL: URL
    private let saveQueue = DispatchQueue(label: "Sprite activity saving", qos: .utility)

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("FortniteSpriteTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saveURL = folder.appendingPathComponent("activity.json")
        load()
    }

    var unreadCount: Int {
        events.filter { !$0.isRead }.count
    }

    var recentEvents: [ActivityEvent] {
        Array(events.prefix(100))
    }

    func add(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > 300 {
            events.removeLast(events.count - 300)
        }
        save()
    }

    func markRead(_ id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].isRead = true
        save()
    }

    func markAllRead() {
        var changed = false
        for index in events.indices where !events[index].isRead {
            events[index].isRead = true
            changed = true
        }
        if changed { save() }
    }

    func clear() {
        events.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let decoded = try? JSONDecoder().decode([ActivityEvent].self, from: data) else {
            events = []
            return
        }
        events = decoded.sorted { $0.date > $1.date }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        let destination = saveURL
        saveQueue.async {
            try? data.write(to: destination, options: .atomic)
        }
    }
}
