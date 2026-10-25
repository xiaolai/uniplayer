//
//  LoadingMediaView.swift
//  uniplayer
//
//  The loading surface shown while the player waits for its first frames.
//

import SwiftUI

@MainActor
final class LoadingMediaModel: ObservableObject {
  enum HealthTone { case good, limited, stalled, waiting, none }
  struct Stat: Identifiable {
    let label: String
    let value: String
    var id: String { label }
  }

  @Published var title = ""
  @Published var subtitle = ""
  @Published var progress: Double?
  @Published var stats: [Stat] = []
  @Published var health: String?
  @Published var healthTone: HealthTone = .none
  @Published var isTorrent = false
}

struct LoadingMediaView: View {
  @ObservedObject var model: LoadingMediaModel
  let onStop: () -> Void

  @AppStorage("interface.textScale.v1") private var textScale = 1.0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .center, spacing: Tokens.Space.n16) {
      badge
        .frame(width: Tokens.Size.n64, height: Tokens.Size.n64)
      VStack(alignment: .leading, spacing: Tokens.Space.n4) {
        Text(model.title)
          .font(Tokens.Typography.detailTitleStrong.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textPrimary.color)
          .lineLimit(3)
          .truncationMode(.middle)
          .help(model.title)
        if !model.subtitle.isEmpty {
          Text(model.subtitle)
            .font(Tokens.Typography.caption.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textSecondary.color)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if let health = model.health {
          Label {
            Text(health)
              .font(Tokens.Typography.caption.scaledFont(textScale))
              .lineLimit(1)
              .truncationMode(.tail)
          } icon: {
            Image(systemName: healthIcon)
          }
          .foregroundStyle(healthColor)
          .padding(.top, Tokens.Space.n4)
        }
      }
      .frame(width: Tokens.Size.n240, alignment: .leading)
      if !model.stats.isEmpty {
        Divider()
          .frame(height: Tokens.Size.n64)
          .padding(.horizontal, Tokens.Space.n4)
        LazyVGrid(columns: [GridItem(.flexible(minimum: Tokens.Size.n60), alignment: .leading),
                            GridItem(.flexible(minimum: Tokens.Size.n60), alignment: .leading)],
                  alignment: .leading, spacing: Tokens.Space.n10) {
          ForEach(model.stats) { stat in
            VStack(alignment: .leading, spacing: Tokens.Space.n2) {
              Text(stat.label)
                .font(Tokens.Typography.caption.scaledFont(textScale))
                .foregroundStyle(Tokens.Palette.textSecondary.color)
              Text(stat.value)
                .font(Tokens.Typography.bodyStrong.scaledFont(textScale))
                .monospacedDigit()
                .foregroundStyle(Tokens.Palette.textPrimary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
          }
        }
      }
      Spacer(minLength: Tokens.Space.n8)
    }
    .padding(Tokens.Space.n24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .topTrailing) {
      Button(action: onStop) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.circle)
      .controlSize(.regular)
      .accessibilityLabel(Text("Stop Loading"))
      .help(Text("Stop Loading"))
      .padding(Tokens.Space.n16)
    }
    .ignoresSafeArea()
  }

  @ViewBuilder
  private var badge: some View {
    if model.isTorrent, let progress = model.progress {
      Gauge(value: progress) {
        Image(systemName: "arrow.down")
      } currentValueLabel: {
        Text(percent(progress))
          .font(Tokens.Typography.captionStrong.scaledFont(textScale))
          .monospacedDigit()
      }
      .gaugeStyle(.accessoryCircularCapacity)
      .tint(Tokens.Palette.accent.color)
      .accessibilityLabel(Text("Torrent progress"))
      .animation(Tokens.Motion.swiftUI(Tokens.Motion.n30, reduceMotion: reduceMotion), value: progress)
    } else {
      ProgressView()
        .controlSize(.large)
        .accessibilityLabel(Text(model.isTorrent ? "Loading torrent" : "Loading media"))
    }
  }

  private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  private var healthIcon: String {
    switch model.healthTone {
    case .good: return "checkmark.circle.fill"
    case .limited: return "exclamationmark.triangle.fill"
    case .stalled: return "xmark.octagon.fill"
    case .waiting: return "clock"
    case .none: return "circle"
    }
  }

  private var healthColor: Color {
    switch model.healthTone {
    case .good: return Tokens.Palette.systemGreen.color
    case .limited: return Tokens.Palette.logWarning.color
    case .stalled: return Tokens.Palette.destructive.color
    case .waiting, .none: return Tokens.Palette.textSecondary.color
    }
  }
}
