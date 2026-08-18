import SwiftUI

struct ProfileComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SpriteStore

    let primaryProfileID: UUID

    @State private var comparisonProfileID: UUID
    @State private var filter: ProfileComparisonFilter = .differences
    @State private var searchText = ""

    init(primaryProfileID: UUID, initialComparisonProfileID: UUID) {
        self.primaryProfileID = primaryProfileID
        _comparisonProfileID = State(initialValue: initialComparisonProfileID)
    }

    var body: some View {
        VStack(spacing: 18) {
            header

            if let primaryProfile, let comparisonProfile {
                profileSelector(primary: primaryProfile, comparison: comparisonProfile)
                summary(primary: primaryProfile, comparison: comparisonProfile)
                controls(primary: primaryProfile, comparison: comparisonProfile)
                comparisonList(primary: primaryProfile, comparison: comparisonProfile)
            } else {
                ContentUnavailableView(
                    "Profiles unavailable",
                    systemImage: "person.2.slash",
                    description: Text("Close this window and choose two saved profiles again.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(width: 980, height: 760)
        .background(AnimatedBackground())
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Compare Collections")
                    .font(.title2.weight(.black))
                Text("See shared Sprites, ownership gaps, and level differences between profiles.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
        }
    }

    private func profileSelector(primary: CollectionProfile, comparison: CollectionProfile) -> some View {
        HStack(spacing: 12) {
            profileIdentity(primary, label: "CURRENT PROFILE")

            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                Text("COMPARE WITH")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.secondary)
                Picker("Compare with", selection: $comparisonProfileID) {
                    ForEach(store.profiles.filter { $0.id != primaryProfileID }) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 230)
            }

            Spacer()

            Text("\(differentRows.count) difference\(differentRows.count == 1 ? "" : "s")")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(15)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
    }

    private func profileIdentity(_ profile: CollectionProfile, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.secondary)
            Label(profile.name, systemImage: "person.crop.circle.fill")
                .font(.headline.weight(.bold))
                .lineLimit(1)
        }
        .frame(minWidth: 230, alignment: .leading)
    }

    private func summary(primary: CollectionProfile, comparison: CollectionProfile) -> some View {
        HStack(spacing: 10) {
            ComparisonSummaryCard(
                title: primary.name,
                value: primary.ownedCount,
                detail: "\(primary.masteredCount) mastered",
                symbol: "person.fill"
            )
            ComparisonSummaryCard(
                title: comparison.name,
                value: comparison.ownedCount,
                detail: "\(comparison.masteredCount) mastered",
                symbol: "person.fill"
            )
            ComparisonSummaryCard(
                title: "Both Own",
                value: rows.filter { $0.primary.owned && $0.comparison.owned }.count,
                detail: "shared collection",
                symbol: "person.2.fill"
            )
            ComparisonSummaryCard(
                title: "Only \(primary.name)",
                value: rows.filter { $0.primary.owned && !$0.comparison.owned }.count,
                detail: "unique to this profile",
                symbol: "arrow.right.circle.fill"
            )
            ComparisonSummaryCard(
                title: "Only \(comparison.name)",
                value: rows.filter { !$0.primary.owned && $0.comparison.owned }.count,
                detail: "unique to this profile",
                symbol: "arrow.left.circle.fill"
            )
        }
    }

    private func controls(primary: CollectionProfile, comparison: CollectionProfile) -> some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(ProfileComparisonFilter.allCases) { option in
                    Text(option.title(primary: primary.name, comparison: comparison.name))
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)

            TextField("Search Sprites", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
        }
    }

    private func comparisonList(primary: CollectionProfile, comparison: CollectionProfile) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("SPRITE")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(primary.name.uppercased())
                    .frame(width: 220, alignment: .leading)
                Text(comparison.name.uppercased())
                    .frame(width: 220, alignment: .leading)
            }
            .font(.caption2.weight(.black))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.45)

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(filteredRows) { row in
                        comparisonRow(row)
                    }
                }
                .padding(10)
            }
        }
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
    }

    private func comparisonRow(_ row: ProfileComparisonRow) -> some View {
        HStack(spacing: 12) {
            CachedSpriteImage(
                assetName: row.primary.imageAssetName,
                accessibilityLabel: row.primary.name
            )
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.primary.name)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                Text(row.primary.rarity.rawValue)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            comparisonStatus(row.primary)
                .frame(width: 220)
            comparisonStatus(row.comparison)
                .frame(width: 220)
        }
        .padding(10)
        .background(rowBackground(row), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(row.isDifferent ? .white.opacity(0.11) : .white.opacity(0.04))
        )
    }

    private func comparisonStatus(_ item: SpriteItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: statusSymbol(item))
                .foregroundStyle(statusColor(item))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle(item))
                    .font(.subheadline.weight(.bold))
                if item.mastered {
                    Text("MASTERED")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.yellow)
                } else if item.owned && item.level == nil {
                    Text("LEVEL UNKNOWN")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(statusColor(item).opacity(item.owned ? 0.11 : 0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private var primaryProfile: CollectionProfile? {
        store.profile(withID: primaryProfileID)
    }

    private var comparisonProfile: CollectionProfile? {
        store.profile(withID: comparisonProfileID)
    }

    private var rows: [ProfileComparisonRow] {
        guard let primaryProfile, let comparisonProfile else { return [] }
        var comparisonByName: [String: SpriteItem] = [:]
        for item in comparisonProfile.sprites {
            comparisonByName[normalized(item.name)] = item
        }

        return primaryProfile.sprites.compactMap { primaryItem in
            guard let comparisonItem = comparisonByName[normalized(primaryItem.name)] else { return nil }
            return ProfileComparisonRow(primary: primaryItem, comparison: comparisonItem)
        }
    }

    private var differentRows: [ProfileComparisonRow] {
        rows.filter(\.isDifferent)
    }

    private var filteredRows: [ProfileComparisonRow] {
        rows.filter { row in
            let matchesSearch = searchText.isEmpty
                || row.primary.name.localizedCaseInsensitiveContains(searchText)

            let matchesFilter: Bool
            switch filter {
            case .differences:
                matchesFilter = row.isDifferent
            case .onlyPrimary:
                matchesFilter = row.primary.owned && !row.comparison.owned
            case .onlyComparison:
                matchesFilter = !row.primary.owned && row.comparison.owned
            case .bothOwned:
                matchesFilter = row.primary.owned && row.comparison.owned
            case .all:
                matchesFilter = true
            }
            return matchesSearch && matchesFilter
        }
    }

    private func statusTitle(_ item: SpriteItem) -> String {
        guard item.owned else { return "Not owned" }
        if let level = item.level {
            return "Level \(level)"
        }
        return "Owned"
    }

    private func statusSymbol(_ item: SpriteItem) -> String {
        guard item.owned else { return "lock.fill" }
        return item.mastered ? "crown.fill" : "checkmark.circle.fill"
    }

    private func statusColor(_ item: SpriteItem) -> Color {
        guard item.owned else { return .secondary }
        return item.mastered ? .yellow : .green
    }

    private func rowBackground(_ row: ProfileComparisonRow) -> Color {
        if row.primary.owned && !row.comparison.owned {
            return .green.opacity(0.08)
        }
        if !row.primary.owned && row.comparison.owned {
            return .purple.opacity(0.10)
        }
        if row.primary.owned && row.comparison.owned && row.primary.level != row.comparison.level {
            return .orange.opacity(0.08)
        }
        return .white.opacity(0.025)
    }

    private func normalized(_ value: String) -> String {
        value.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
}

private enum ProfileComparisonFilter: String, CaseIterable, Identifiable {
    case differences
    case onlyPrimary
    case onlyComparison
    case bothOwned
    case all

    var id: String { rawValue }

    func title(primary: String, comparison: String) -> String {
        switch self {
        case .differences: "Differences"
        case .onlyPrimary: "Only \(primary)"
        case .onlyComparison: "Only \(comparison)"
        case .bothOwned: "Both Own"
        case .all: "All"
        }
    }
}

private struct ProfileComparisonRow: Identifiable {
    let primary: SpriteItem
    let comparison: SpriteItem

    var id: String { primary.name }

    var isDifferent: Bool {
        primary.owned != comparison.owned
            || primary.level != comparison.level
    }
}

private struct ComparisonSummaryCard: View {
    let title: String
    let value: Int
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(value)")
                    .font(.title2.monospacedDigit().weight(.black))
            }
            Text(title)
                .font(.caption.weight(.heavy))
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.07)))
    }
}
