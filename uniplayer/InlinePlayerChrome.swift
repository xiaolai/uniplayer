//
//  InlinePlayerChrome.swift
//  uniplayer
//
//  The inline player's control overlay: one SwiftUI layer over the video,
//  built from the measured HUD tokens. It replaces the floating OSC and HUD
//  windows while the library detail owns the surface.
//

import AppKit
import SwiftUI

private func inlineL(_ key: String) -> String {
  NSLocalizedString(key, comment: "")
}

// MARK: - Model

/// Published state for the inline controls. It reads `PlayerCore` and forwards
/// every action back to it; it never owns playback state of its own.
final class InlinePlayerModel: ObservableObject {

  @Published private(set) var isActive = false
  @Published private(set) var isPaused = true
  @Published private(set) var position: Double = 0
  @Published private(set) var duration: Double = 0
  @Published private(set) var volume: Double = 0
  @Published private(set) var isMuted = false
  @Published private(set) var speed: Double = 1
  @Published private(set) var currentURL: URL?
  @Published private(set) var audioTracks: [MPVTrack] = []
  @Published private(set) var subTracks: [MPVTrack] = []
  @Published private(set) var selectedAudioID: Int?
  @Published private(set) var selectedSubID: Int?
  @Published private(set) var message: String?
  @Published private(set) var isFullscreen = false
  @Published private(set) var controlsVisible = true

  /// Set when playback was paused because the user navigated off the detail;
  /// returning to the item resumes it.
  private(set) var pausedForNavigation = false
  /// The file that pause belongs to.
  private var pausedURL: URL?

  /// Toggles the library window's fullscreen. Set by the library view.
  var onToggleFullscreen: (() -> Void)?
  /// Opens playback in the detached player window.
  var onOpenInNewWindow: (() -> Void)?

  private unowned let player: PlayerCore
  private var hideControlsTask: DispatchWorkItem?
  private var hideMessageTask: DispatchWorkItem?
  private var pointerOverControls = false

  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      || Preference.bool(for: .disableAnimations)
  }

  init(player: PlayerCore) {
    self.player = player
    player.inlineOSDHandler = { [weak self] osd in
      self?.show(osd)
    }
    player.inlineRefreshHandler = { [weak self] in
      self?.refresh()
    }
    player.inlineHideOSDHandler = { [weak self] in
      self?.hideMessage()
    }
  }

  // MARK: Reading the player

  func refresh() {
    let info = player.info
    isActive = player.isInline && info.state.active
    let nowPaused = info.state == .paused
    if nowPaused != isPaused {
      isPaused = nowPaused
      // A keyboard pause reveals the controls and leaves them up; resuming
      // starts the auto-hide clock again.
      if nowPaused {
        cancelHide()
        controlsVisible = true
      } else {
        scheduleHide()
      }
    }
    position = info.videoPosition?.second ?? 0
    duration = info.videoDuration?.second ?? 0
    volume = info.volume
    isMuted = info.isMuted
    speed = info.playSpeed
    audioTracks = info.audioTracks
    subTracks = info.subTracks
    selectedAudioID = info.aid
    selectedSubID = info.sid
    if let url = info.currentURL, pausedForNavigation, pausedURL != url {
      // Playback moved to another file; the old pause no longer applies.
      pausedForNavigation = false
      pausedURL = nil
    }
    currentURL = info.currentURL
    if let provider = fullscreenProvider {
      isFullscreen = provider()
    }
  }

  /// The library window reports its own fullscreen state.
  var fullscreenProvider: (() -> Bool)?

  // MARK: Visibility

  func registerActivity() {
    controlsVisible = true
    scheduleHide()
  }

  func setPointerOverControls(_ hovering: Bool) {
    pointerOverControls = hovering
    if hovering {
      cancelHide()
      controlsVisible = true
    } else {
      scheduleHide()
    }
  }

  private func scheduleHide() {
    guard !isPaused, !pointerOverControls else { return }
    cancelHide()
    let timeout = TimeInterval(Preference.float(for: .controlBarAutoHideTimeout))
    let task = DispatchWorkItem { [weak self] in
      guard let self, !self.isPaused, !self.pointerOverControls else { return }
      withAnimation(Tokens.Motion.swiftUI(Tokens.Motion.hud, reduceMotion: self.reduceMotion)) {
        self.controlsVisible = false
      }
    }
    hideControlsTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: task)
  }

  private func cancelHide() {
    hideControlsTask?.cancel()
    hideControlsTask = nil
  }

  // MARK: Messages

  private func show(_ osd: OSDMessage) {
    let text = osd.titleAndType().0
    guard !text.isEmpty else { return }
    message = text
    hideMessageTask?.cancel()
    let timeout = TimeInterval(Preference.float(for: .osdAutoHideTimeout))
    let task = DispatchWorkItem { [weak self] in
      self?.message = nil
    }
    hideMessageTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: task)
  }

  func hideMessage() {
    hideMessageTask?.cancel()
    hideMessageTask = nil
    message = nil
  }

  // MARK: Actions

  func togglePlayPause() {
    player.togglePause()
    refresh()
    registerActivity()
  }

  func skip(by seconds: Double) {
    player.seek(relativeSecond: seconds, option: .defaultValue)
    refresh()
    registerActivity()
  }

  func seek(to seconds: Double) {
    guard duration > 0 else { return }
    player.seek(absoluteSecond: seconds.clamped(to: 0...duration))
    refresh()
  }

  func setVolume(_ value: Double) {
    player.setVolume(value)
    refresh()
  }

  func toggleMute() {
    player.toggleMute()
    refresh()
  }

  func setSpeed(_ value: Double) {
    player.setSpeed(value)
    refresh()
  }

  func selectAudio(_ track: MPVTrack) {
    player.setTrack(track.id, forType: .audio)
    refresh()
  }

  func selectSubtitle(_ track: MPVTrack) {
    player.setTrack(track.id, forType: .sub)
    refresh()
  }

  func toggleFullscreen() {
    onToggleFullscreen?()
  }

  // MARK: Navigation lifecycle

  /// Pauses because the detail is leaving the screen. Returns `true` when the
  /// pause was ours to resume.
  @discardableResult
  func pauseForNavigation() -> Bool {
    guard isActive, !isPaused else { return false }
    player.pause()
    pausedForNavigation = true
    pausedURL = currentURL ?? player.info.currentURL
    refresh()
    return true
  }

  /// Resumes playback that `pauseForNavigation` stopped, but only when the
  /// detail the user returned to holds the same file.
  func resumeIfPausedForNavigation(for url: URL?) {
    guard pausedForNavigation else { return }
    guard let expected = pausedURL, let url, expected == url else {
      pausedForNavigation = false
      pausedURL = nil
      return
    }
    pausedForNavigation = false
    pausedURL = nil
    guard isActive else { return }
    player.resume()
    refresh()
    registerActivity()
  }
}

// MARK: - Overlay

struct InlinePlayerChrome: View {
  @ObservedObject var model: InlinePlayerModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var scrubbing = false
  @State private var scrubValue: Double = 0

  private var displayedPosition: Double {
    scrubbing ? scrubValue : model.position
  }

  var body: some View {
    ZStack {
      if model.controlsVisible || model.message != nil {
        backdrop
      }
      VStack(spacing: Tokens.Space.n0) {
        if let message = model.message {
          messageChip(message)
            .padding(.top, Tokens.HUD.topMargin)
        }
        Spacer(minLength: Tokens.Space.n0)
        if model.controlsVisible {
          controls
            .transition(.opacity)
        }
      }
    }
    .animation(Tokens.Motion.swiftUI(Tokens.Motion.hud, reduceMotion: reduceMotion),
               value: model.controlsVisible)
    .accessibilityElement(children: .contain)
  }

  private var backdrop: some View {
    LinearGradient(
      colors: [Tokens.Palette.clear.color,
               Tokens.Palette.hudBottomShade.color.opacity(Tokens.Opacity.n55)],
      startPoint: .center,
      endPoint: .bottom)
      .allowsHitTesting(false)
  }

  private var controls: some View {
    VStack(spacing: Tokens.HUD.controlSpacing) {
      timeline
      transport
    }
    .padding(.horizontal, Tokens.HUD.bottomMargin)
    .padding(.vertical, Tokens.HUD.controlSpacing)
    .padding(.bottom, Tokens.HUD.timelineBottom)
    .background {
      RoundedRectangle(cornerRadius: Tokens.HUD.timelineCorner, style: .continuous)
        .fill(Tokens.Palette.hudGlassTint.color.opacity(Tokens.Opacity.n68))
    }
    .padding(.horizontal, Tokens.Space.n16)
    // Only the controls themselves hold the pointer; hovering the video must
    // still let the bar auto-hide.
    .onHover { model.setPointerOverControls($0) }
  }

  // MARK: Timeline

  private var timeline: some View {
    HStack(spacing: Tokens.Space.n8) {
      Text(VideoTime(displayedPosition).stringRepresentation)
        .font(Tokens.Typography.numeric.font)
        .foregroundStyle(Tokens.Palette.onMediaSecondary.color)
        .monospacedDigit()

      InlineSlider(
        value: Binding(
          get: { displayedPosition },
          set: { scrubValue = $0 }),
        range: 0...max(model.duration, 1),
        label: inlineL("Playback position")) { editing in
          if editing {
            scrubbing = true
            scrubValue = model.position
          } else {
            scrubbing = false
            model.seek(to: scrubValue)
          }
        }

      Text(VideoTime(model.duration).stringRepresentation)
        .font(Tokens.Typography.numeric.font)
        .foregroundStyle(Tokens.Palette.onMediaSecondary.color)
        .monospacedDigit()
    }
    .padding(.horizontal, Tokens.HUD.timelineHeight)
  }

  // MARK: Transport

  private var transport: some View {
    HStack(spacing: Tokens.HUD.transportSpacingLegacy) {
      controlButton(model.isPaused ? "play.fill" : "pause.fill",
                    label: model.isPaused ? inlineL("Play") : inlineL("Pause")) {
        model.togglePlayPause()
      }

      controlButton("gobackward.10", label: inlineL("Back 10 Seconds")) {
        model.skip(by: -10)
      }

      controlButton("goforward.10", label: inlineL("Forward 10 Seconds")) {
        model.skip(by: 10)
      }

      Spacer(minLength: Tokens.Space.n8)

      audioMenu
      subtitleMenu
      speedMenu

      controlButton(model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    label: model.isMuted ? inlineL("Unmute") : inlineL("Mute")) {
        model.toggleMute()
      }

      Slider(
        value: Binding(
          get: { model.volume },
          set: { model.setVolume($0) }),
        in: 0...Double(Preference.integer(for: .maxVolume)))
      .frame(width: Tokens.Size.n70)
      .tint(Tokens.Palette.onMedia.color)
      .accessibilityLabel(Text(inlineL("Volume")))
      .help(inlineL("Volume"))

      controlButton(model.isFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                    label: model.isFullscreen
                      ? inlineL("Exit Full Screen") : inlineL("Enter Full Screen")) {
        model.toggleFullscreen()
      }
    }
    .padding(.horizontal, Tokens.HUD.timelineHeight)
  }

  private func controlButton(_ symbol: String, label: String,
                             action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(Tokens.Typography.body.font)
        .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(Tokens.Palette.onMedia.color)
    .accessibilityLabel(label)
    .help(label)
  }

  private var audioMenu: some View {
    Menu {
      ForEach(model.audioTracks, id: \.id) { track in
        Button {
          model.selectAudio(track)
        } label: {
          if model.selectedAudioID == track.id {
            Label(track.readableTitle, systemImage: "checkmark")
          } else {
            Text(track.readableTitle)
          }
        }
      }
    } label: {
      Image(systemName: "waveform")
        .font(Tokens.Typography.body.font)
        .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .foregroundStyle(Tokens.Palette.onMedia.color)
    .accessibilityLabel(inlineL("Audio Track"))
  }

  private var subtitleMenu: some View {
    Menu {
      Button(inlineL("Off")) {
        model.selectSubtitle(MPVTrack.noneSubTrack)
      }
      ForEach(model.subTracks, id: \.id) { track in
        Button {
          model.selectSubtitle(track)
        } label: {
          if model.selectedSubID == track.id {
            Label(track.readableTitle, systemImage: "checkmark")
          } else {
            Text(track.readableTitle)
          }
        }
      }
    } label: {
      Image(systemName: "captions.bubble")
        .font(Tokens.Typography.body.font)
        .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .foregroundStyle(Tokens.Palette.onMedia.color)
    .accessibilityLabel(inlineL("Subtitles"))
  }

  private var speedMenu: some View {
    Menu {
      ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
        Button {
          model.setSpeed(speed)
        } label: {
          if abs(model.speed - speed) < 0.001 {
            Label(speedLabel(speed), systemImage: "checkmark")
          } else {
            Text(speedLabel(speed))
          }
        }
      }
    } label: {
      Text(speedLabel(model.speed))
        .font(Tokens.Typography.numeric.font)
        .frame(minWidth: Tokens.Size.n30, minHeight: Tokens.Size.n30)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .foregroundStyle(Tokens.Palette.onMedia.color)
    .accessibilityLabel(inlineL("Playback Speed"))
  }

  private func speedLabel(_ speed: Double) -> String {
    // Three significant digits keeps 1.25× exact while still trimming 1.0 to 1.
    String(format: "%.3g×", speed)
  }

  private func messageChip(_ message: String) -> some View {
    Text(message)
      .font(Tokens.Typography.caption.font)
      .foregroundStyle(Tokens.Palette.onMedia.color)
      .padding(.horizontal, Tokens.HUD.capsuleHorizontal)
      .padding(.vertical, Tokens.HUD.capsuleVertical)
      .glassEffect(.regular, in: .capsule)
      .accessibilityAddTraits(.isStaticText)
  }
}


// MARK: - Labelled slider

/// A SwiftUI `Slider` does not expose an accessibility name in this embedded
/// layout, so the inline controls use a real `NSSlider`, which carries both a
/// role and an explicit label.
private struct InlineSlider: NSViewRepresentable {
  @Binding var value: Double
  let range: ClosedRange<Double>
  let label: String
  var onEditingChanged: (Bool) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> SliderView {
    let slider = SliderView(value: value,
                            minValue: range.lowerBound,
                            maxValue: range.upperBound,
                            target: context.coordinator,
                            action: #selector(Coordinator.valueChanged(_:)))
    slider.isContinuous = true
    slider.controlSize = .small
    slider.setAccessibilityLabel(label)
    slider.onEditingChanged = { [weak coordinator = context.coordinator] editing in
      coordinator?.parent.onEditingChanged(editing)
    }
    context.coordinator.slider = slider
    return slider
  }

  func updateNSView(_ nsView: SliderView, context: Context) {
    context.coordinator.parent = self
    nsView.minValue = range.lowerBound
    nsView.maxValue = range.upperBound
    nsView.setAccessibilityLabel(label)
    if !context.coordinator.isDragging {
      nsView.doubleValue = value
    }
  }

  final class Coordinator: NSObject {
    var parent: InlineSlider
    weak var slider: SliderView?
    var isDragging = false

    init(_ parent: InlineSlider) { self.parent = parent }

    @objc func valueChanged(_ sender: NSSlider) {
      parent.value = sender.doubleValue
    }
  }

  final class SliderView: NSSlider {
    var onEditingChanged: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
      onEditingChanged?(true)
      super.mouseDown(with: event)
      onEditingChanged?(false)
    }
  }
}
