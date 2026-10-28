import SwiftUI

/// The Connections tab: what passed between besir and other apps or services, newest flow first. It only draws the log;
/// it has no button, no caption and no way to add a row.
struct ConnectionsView: View {
    @ObservedObject private var log = ConnectionLog.shared

    var body: some View {
        let flows = ConnectionFlows.shown(log.packets)
        ScrollView {
            if flows.isEmpty {
                Text(ConnectionLog.emptyText)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(flows) { flow in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ConnectionFlows.chainText(flow))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            ForEach(flow.packets) { packet in
                                packetLine(packet)
                            }
                            Divider().overlay(Theme.line)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One line. The summary has the lowest layout priority, so it is cut with `…` before the kind, the status or the time.
    private func packetLine(_ packet: ConnectionPacket) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(packet.kind.displayName)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .layoutPriority(1)
            Text(packet.summary)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Label(packet.status.word, systemImage: Self.symbol(packet.status))
                .foregroundStyle(Self.color(packet.status))
                .lineLimit(1)
                .layoutPriority(1)
            Text(ConnectionLog.timeText(packet.at, now: Date()))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .font(.footnote)
    }

    static func symbol(_ status: ConnectionStatus) -> String {
        switch status {
        case .ok: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .declined: return "minus.circle"
        case .noRoute: return "location.slash"
        }
    }

    static func color(_ status: ConnectionStatus) -> Color {
        switch status {
        case .ok: return Theme.travel
        case .failed: return Theme.warn
        case .declined, .noRoute: return Theme.muted
        }
    }
}
