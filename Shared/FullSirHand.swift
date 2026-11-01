import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// SPEC-FULLHAND-001 (card t101): the screens of the hand path on be full sir. They only call what the other files built: the toolbox's
// partner card, the one cancel, the history rows and the photo loader. None of them makes a model request.

/// A partner card opened by hand, wrapped so a sheet can hold it by identity.
struct HandCard: Identifiable {
    let id = UUID()
    let card: AgentCard
}

/// Hosts one partner card in a sheet. While the card waits it draws the card's own edit card with its own Confirm and Cancel; after the
/// card resolves it shows the card's lines, its mark and its notice, the same texts the chat shows. Closing the sheet while the card
/// waits resolves it as dismissed. The Google Maps mark stays whenever the card carries one.
struct PartnerCardSheet: View {
    let card: AgentCard

    @State private var resolving = false
    @State private var mark: AgentCardMark?
    @State private var notice: String?

    var body: some View {
        ScrollView {
            if let fieldCard = card.fieldCard {
                PartnerCardContent(card: card, fieldCard: fieldCard, resolving: resolving, mark: mark, notice: notice,
                                   onConfirm: { resolve(.confirm) }, onCancel: { resolve(.cancel) })
                    .padding(16)
            }
        }
        .background(Theme.bg)
        // A card that was already resolved ignores this: only the first resolution acts.
        .onDisappear { Task { _ = await card.resolve(.dismiss) } }
    }

    private func resolve(_ how: AgentCardResolution) {
        guard !resolving, mark == nil else { return }
        resolving = true
        Task {
            let resolution = await card.resolve(how)
            resolving = false
            guard let resolution else { return }
            notice = resolution.notice
            mark = card.mark
        }
    }
}

/// The card's rows or, once resolved, its lines; observes the field card so a change redraws Confirm.
private struct PartnerCardContent: View {
    let card: AgentCard
    @ObservedObject var fieldCard: AgentFieldCard
    let resolving: Bool
    let mark: AgentCardMark?
    let notice: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mark {
                ForEach(Array(fieldCard.lines.enumerated()), id: \.offset) { index, line in
                    Text(verbatim: line)
                        .font(index == 0 ? .headline : .body)
                        .foregroundStyle(Theme.ink)
                }
                if card.showsGoogleMark {
                    GoogleMapsAttribution()
                }
                Text(verbatim: mark.rawValue)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                if let notice {
                    Text(verbatim: notice)
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                }
            } else {
                EditCardView(card: fieldCard.card, busy: resolving, actions: fieldCard.actions,
                             chrome: EditCardChrome(header: fieldCard.header, confirmTitle: nil))
                if card.showsGoogleMark {
                    GoogleMapsAttribution()
                }
                HStack(spacing: 12) {
                    Button("Confirm", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .disabled(!(fieldCard.isReady && card.canConfirm))
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                }
                .disabled(resolving)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The partner requests that made an entry the schedule still holds, one row each, with the one cancel. Read when it appears and after
/// each cancel. An empty list shows nothing but the title and the close button.
struct PartnerHistoryView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [PartnerHistoryRow] = []
    /// Rows whose cancel is running.
    @State private var cancelling: Set<UUID> = []
    /// Rows whose last cancel changed nothing.
    @State private var refused: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        historyRow(row)
                        Divider().overlay(Theme.line)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .onAppear(perform: reload)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func historyRow(_ row: PartnerHistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.title).font(.subheadline).bold()
                    Text(verbatim: Self.range(row.start, row.end)).font(.caption).foregroundStyle(Theme.muted)
                    if let place = row.place {
                        Text(verbatim: place.name).font(.caption).foregroundStyle(Theme.muted)
                        if !place.address.isEmpty {
                            Text(verbatim: place.address).font(.caption2).foregroundStyle(Theme.faint)
                        }
                    }
                    if let cents = row.estimateCents {
                        Text(verbatim: PartnerHand.estimateText(cents: cents)).font(.caption).foregroundStyle(Theme.muted)
                    }
                    Text(verbatim: AgentPartner.partnerLine(row.partnerName)).font(.caption2).foregroundStyle(Theme.faint)
                }
                Spacer()
                if cancelling.contains(row.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { cancel(row) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cancel")
                }
            }
            if refused.contains(row.id) {
                Text(verbatim: PartnerCancel.notCancelledNotice).font(.caption).foregroundStyle(Theme.warn)
            }
        }
    }

    private func reload() {
        rows = PartnerHistory.rows(records: PartnerRecords.shared, store: store)
    }

    /// One tap runs the one cancel. A second tap while it runs is ignored. A cancel the partner refused, or that failed, leaves the row.
    private func cancel(_ row: PartnerHistoryRow) {
        guard !cancelling.contains(row.id) else { return }
        cancelling.insert(row.id)
        refused.remove(row.id)
        // The client is built as the toolbox builds its own: from the live configuration, over an ephemeral session.
        let client = PartnerClient(config: store.config, send: { try await URLSession(configuration: .ephemeral).data(for: $0) })
        Task {
            let outcome = await PartnerCancel.run(activityID: row.id, store: store, records: PartnerRecords.shared,
                                                  ledger: BudgetLedger.shared, client: client)
            cancelling.remove(row.id)
            switch outcome {
            case .declined, .unavailable: refused.insert(row.id)
            case .cancelled, .noRecord: break
            }
            reload()
        }
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "M/d EEE h:mm a"; return f
    }()
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "h:mm a"; return f
    }()

    private static func range(_ start: Date, _ end: Date) -> String {
        let second = Calendar.current.isDate(start, inSameDayAs: end) ? timeFormat : dayFormat
        return "\(dayFormat.string(from: start)) - \(second.string(from: end))"
    }
}

/// The photos of an expanded row: up to three, loaded once each while the row stays open, each with its author's name directly under it.
/// Image data and the names that failed live only in this view's state, so collapsing the row drops them. A photo that fails draws
/// nothing. Without photos or without the proxy the strip draws nothing at all.
struct PlacePhotoStrip: View {
    let photos: [NearbyPhoto]
    @EnvironmentObject var store: Store

    @State private var images: [String: Image] = [:]
    @State private var failed: Set<String> = []

    /// The height the strip keeps for itself while a photo is on its way or shown, so the buttons below do not move when it arrives.
    static func reservedHeight(photos: [NearbyPhoto], loaded: Set<String>, failed: Set<String>) -> CGFloat {
        photos.contains { !failed.contains($0.name) || loaded.contains($0.name) } ? photoHeight + authorLineHeight : 0
    }

    private static let photoHeight: CGFloat = 140
    private static let authorLineHeight: CGFloat = 18

    var body: some View {
        if !photos.isEmpty && store.config.hasProxy {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(photos, id: \.name) { photo in
                        if let image = images[photo.name] {
                            VStack(alignment: .leading, spacing: 2) {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 200, height: Self.photoHeight)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                                    .accessibilityHidden(true)
                                if !photo.author.isEmpty {
                                    if let url = photo.authorURL {
                                        Link(photo.author, destination: url)
                                    } else {
                                        Text(verbatim: photo.author)
                                    }
                                }
                            }
                            .font(.caption2)
                            .frame(width: 200, alignment: .leading)
                        }
                    }
                }
            }
            .frame(minHeight: Self.reservedHeight(photos: photos, loaded: Set(images.keys), failed: failed), alignment: .top)
            .task { await load() }
        }
    }

    /// Asks each photo not yet shown and not yet failed, one after the other. The task ends with the row.
    private func load() async {
        for photo in photos where images[photo.name] == nil && !failed.contains(photo.name) {
            let data: Data?
            if let request = PlacePhotos.request(name: photo.name, config: store.config) {
                data = await PlacePhotos.fetch(request, transport: PlacePhotos.ephemeral)
            } else {
                data = nil
            }
            if Task.isCancelled { return }
            if let data, let image = Self.image(from: data) {
                images[photo.name] = image
            } else {
                failed.insert(photo.name)
            }
        }
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}
