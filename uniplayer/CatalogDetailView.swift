//
//  CatalogDetailView.swift
//  uniplayer
//
//  Detail for a catalog item. It shows the live inline surface when that item
//  is the one playing, and otherwise the metadata and the explicit playback
//  intents. Organization actions use the same reason-safe store as the browser.
//

import AppKit
import SwiftUI

private func L(_ key: String) -> String {
  NSLocalizedString(key, comment: "")
}

struct CatalogDetailView: View {
  @Environment(\.libraryTextScale) private var textScale
  let mediaID: UUID
  let catalog: MediaCatalog
  let coordinator: SourceCoordinator
  @ObservedObject var inlinePlayer: InlinePlayerModel
  let host: InlinePlayerSurfaceHost
  let onPlay: (PlaybackIntent) -> Void
  let onBack: () -> Void
  let onRelink: (UUID) -> Void
  let onShowProperties: (UUID) -> Void
  let onShowInFinder: (URL) -> Void
  /// While the video owns a fullscreen window, this page must not keep a
  /// second InlinePlayerView mounted: both would attach the same surface host.
  var videoFullscreenPresented = false

  @State private var media: CatalogMedia?
  @State private var showCollectionPicker = false
  @State private var collections: [MediaCollection] = []
  @State private var errorMessage: String?
  @State private var loadError: String?
  @State private var didLoad = false

  private var organization: MediaOrganizationStore { coordinator.organization }

  private var isPlayingHere: Bool {
    guard inlinePlayer.isActive, let current = inlinePlayer.currentURL,
          let url = media?.url else { return false }
    return current == url
  }

  var body: some View {
    ZStack {
      if isPlayingHere, !videoFullscreenPresented {
        liveSurface
      } else {
        page
      }
    }
    .background(Tokens.Palette.canvas.color)
    .task(id: mediaID) {
      await reload()
      collections = coordinator.collections
    }
    .onAppear { inlinePlayer.refresh() }
    .onDisappear {
      // Pause only when this page was playing its own item. A playback
      // replacement has already switched to another file; pausing here would
      // stop that file instead.
      if inlinePlayer.currentURL == media?.url {
        inlinePlayer.pauseForNavigation()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .mediaCatalogDidChange)) { _ in
      Task { await reload() }
    }
    .sheet(isPresented: $showCollectionPicker) {
      CollectionPickerSheet(
        collections: collections,
        onCreate: { name in
          let id = try? await coordinator.createCollection(name: name)
          collections = coordinator.collections
          return id
        },
        onPick: { collectionID in
          Task {
            do {
              try await organization.addToCollection([mediaID], to: collectionID)
              showCollectionPicker = false
              await reload()
            } catch {
              errorMessage = (error as? MediaSourceError)?.userMessage
                ?? String(describing: error)
            }
          }
        })
    }
    .alert(L("Source Error"), isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } })) {
      Button(L("OK")) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var page: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n20) {
        Button(action: onBack) {
          Label(NSLocalizedString("Back", comment: ""), systemImage: "chevron.left")
            .font(Tokens.Typography.body.scaledFont(textScale))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .accessibilityLabel(NSLocalizedString("Back", comment: ""))

        if let media {
          poster(media)
            .aspectRatio(Tokens.Aspect.video, contentMode: .fit)
            .frame(maxHeight: Tokens.Library.heroMaximumHeight)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous)
                .stroke(Tokens.Palette.separator.color, lineWidth: Tokens.Stroke.hairline)
            }

          Text(media.name)
            .font(Tokens.Typography.heroTitle.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textPrimary.color)
            .lineLimit(2)
            .truncationMode(.middle)
          Text(media.rootDisplayName ?? NSLocalizedString("Library", comment: ""))
            .font(Tokens.Typography.body.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textSecondary.color)

          actionRow(media)
          metadata(media)
        } else if let loadError, didLoad {
          EmptyStateView(
            symbol: "exclamationmark.triangle",
            title: L("Could Not Load Item"),
            message: loadError,
            actionTitle: L("Try Again")) { Task { await reload() } }
            .frame(maxHeight: .infinity)
        } else if didLoad {
          EmptyStateView(
            symbol: "questionmark.folder",
            title: L("Item Not Found"),
            message: L("It may have been removed or relinked."),
            actionTitle: L("Back")) { onBack() }
            .frame(maxHeight: .infinity)
        } else {
          LibraryLoadingState()
        }
      }
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.top, Tokens.Space.pageTop)
      .padding(.bottom, Tokens.Space.pageBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func poster(_ media: CatalogMedia) -> some View {
    Tokens.Palette.surface.color
      .overlay {
        if MediaArtworkPolicy.shouldLoadArtwork(for: media), let url = media.url {
          PosterImage(url: url)
        } else {
          Image(systemName: media.reasons.contains(.favorite) ? "star.fill" : "play.rectangle.fill")
            .font(.system(size: Tokens.Library.placeholderGlyph, weight: .regular))
            .foregroundStyle(Tokens.Palette.textTertiary.color)
        }
      }
  }

  private func actionRow(_ media: CatalogMedia) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Tokens.Space.n12) { primaryAction(media); secondaryActions(media) }
      VStack(alignment: .leading, spacing: Tokens.Space.n12) {
        primaryAction(media)
        secondaryActions(media)
      }
    }
  }

  private func primaryAction(_ media: CatalogMedia) -> some View {
    Button {
      onPlay(media.isResumable ? .resume : .ordinaryOpen)
    } label: {
      Label(media.isResumable
            ? NSLocalizedString("Resume", comment: "")
            : NSLocalizedString("Play", comment: ""),
            systemImage: "play.fill")
        .font(Tokens.Typography.button.scaledFont(textScale))
    }
    .buttonStyle(.borderedProminent)
    .keyboardShortcut(.defaultAction)
    .disabled(media.presence == .missing)
  }

  private func secondaryActions(_ media: CatalogMedia) -> some View {
    HStack(spacing: Tokens.Space.n12) {
      Button(NSLocalizedString("Play from Beginning", comment: "")) { onPlay(.fromBeginning) }
        .buttonStyle(.bordered)
      Button(media.isFinished
             ? NSLocalizedString("Mark Unwatched", comment: "")
             : NSLocalizedString("Mark Watched", comment: "")) {
        Task {
          if media.isFinished {
            try? await organization.resetUnwatched([media.id])
          } else {
            try? await organization.markWatched(true, mediaIDs: [media.id])
          }
          await reload()
        }
      }
      .buttonStyle(.bordered)
      Button(media.reasons.contains(.favorite)
             ? NSLocalizedString("Remove from Favorites", comment: "")
             : NSLocalizedString("Add to Favorites", comment: "")) {
        Task {
          try? await organization.setFavorite(!media.reasons.contains(.favorite),
                                              mediaIDs: [media.id])
          await reload()
        }
      }
      .buttonStyle(.bordered)
      Button(NSLocalizedString("Add to Collection…", comment: "")) {
        showCollectionPicker = true
      }
      .buttonStyle(.bordered)
      Menu {
        if let url = media.url, url.isFileURL {
          Button(NSLocalizedString("Show in Finder", comment: "")) { onShowInFinder(url) }
        }
        Button(media.isHidden
               ? NSLocalizedString("Show in Library", comment: "")
               : NSLocalizedString("Hide from Library", comment: "")) {
          Task {
            try? await organization.setHidden(!media.isHidden, mediaIDs: [media.id])
            await reload()
          }
        }
        Button(NSLocalizedString("Relink…", comment: "")) { onRelink(media.id) }
        if let rootID = media.rootID {
          Button(NSLocalizedString("Source Settings…", comment: "")) { onShowProperties(rootID) }
        }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help(NSLocalizedString("More Actions", comment: ""))
    }
  }

  private func metadata(_ media: CatalogMedia) -> some View {
    Grid(alignment: .leading, horizontalSpacing: Tokens.Space.n24,
         verticalSpacing: Tokens.Space.n8) {
      detailRow(NSLocalizedString("Source", comment: ""),
                media.rootDisplayName ?? NSLocalizedString("Library", comment: ""))
      if let path = media.relativePath {
        detailRow(NSLocalizedString("Location", comment: ""), path)
      }
      if let duration = media.duration ?? media.playState?.observedDuration {
        detailRow(NSLocalizedString("Duration", comment: ""),
                  VideoTime(duration).stringRepresentation)
      }
      if let size = media.size {
        detailRow(NSLocalizedString("Size", comment: ""),
                  ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
      }
      if let modified = media.modifiedAt {
        detailRow(NSLocalizedString("Modified", comment: ""),
                  modified.formatted(date: .abbreviated, time: .shortened))
      }
      detailRow(NSLocalizedString("Availability", comment: ""), availability(media))
      if let state = media.playState {
        detailRow(NSLocalizedString("Progress", comment: ""),
                  "\(VideoTime(state.observedPosition).stringRepresentation) / \(VideoTime(state.observedDuration ?? 0).stringRepresentation)")
      }
    }
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .font(Tokens.Typography.caption.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .gridColumnAlignment(.trailing)
      Text(value)
        .font(Tokens.Typography.body.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textPrimary.color)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
  }

  private func availability(_ media: CatalogMedia) -> String {
    switch media.presence {
    case .present: return NSLocalizedString("Available", comment: "")
    case .missing: return NSLocalizedString("Missing", comment: "")
    case .unknown: return NSLocalizedString("Unknown", comment: "")
    }
  }

  private var liveSurface: some View {
    Tokens.Palette.black.color
      .overlay {
        ZStack {
          InlinePlayerView(host: host)
          InlinePlayerChrome(model: inlinePlayer)
        }
      }
      .aspectRatio(Tokens.Aspect.video, contentMode: .fit)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
  }

  private func reload() async {
    do {
      media = try await catalog.media(id: mediaID)
      loadError = nil
    } catch {
      media = nil
      loadError = (error as? MediaSourceError)?.userMessage
        ?? String(describing: error)
    }
    didLoad = true
  }
}
