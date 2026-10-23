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

enum InlineLoadingStatus {
  static func message(state: PlayerState, pausedForCache: Bool, showBuffering: Bool) -> String? {
    guard state.active else { return nil }
    if state == .loading || state == .starting { return inlineL("Opening video…") }
    if pausedForCache && showBuffering { return inlineL("Buffering…") }
    return nil
  }
}

struct InlineLoadingIndicator: View {
  let message: String
  var body: some View {
    VStack(spacing: Tokens.Space.n8) {
      ProgressView().progressViewStyle(.circular).controlSize(.small)
        .environment(\.colorScheme, Tokens.Library.mediaOverlayColorScheme)
      Text(message).font(Tokens.Typography.caption.font)
        .shadow(color: Tokens.Palette.black.color, radius: Tokens.Space.n2)
    }
    .foregroundStyle(Tokens.Palette.onMedia.color)
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(message)
  }
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
  @Published private(set) var loadingMessage: String?

  /// Toggles the video-only fullscreen presentation. Set by the library view.
  var onToggleFullscreen: (() -> Void)?
  /// Opens playback in the detached player window.
  var onOpenInNewWindow: (() -> Void)?

  private unowned let player: PlayerCore
  private var hideControlsTask: DispatchWorkItem?
  private var hideMessageTask: DispatchWorkItem?
  private var pointerOverControls = false
  private var controlsHaveFocus = false
  private var menuIsOpen = false

  func holdControlsForFocus(_ focused: Bool) {
    controlsHaveFocus = focused
    registerActivity()
  }

  func holdControlsForMenu(_ open: Bool) {
    menuIsOpen = open
    registerActivity()
  }

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
    loadingMessage = InlineLoadingStatus.message(state: info.state,
      pausedForCache: info.pausedForCache, showBuffering: Preference.bool(for: .showBufferingThrobber))
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
    currentURL = info.currentURL
    if let provider = fullscreenProvider {
      isFullscreen = provider()
    }
  }

  /// Reports the video-only fullscreen presentation state.
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
    guard !isPaused, !pointerOverControls, !controlsHaveFocus, !menuIsOpen else { return }
    cancelHide()
    let timeout = TimeInterval(Preference.float(for: .controlBarAutoHideTimeout))
    let task = DispatchWorkItem { [weak self] in
      guard let self, !self.isPaused, !self.pointerOverControls, !self.controlsHaveFocus, !self.menuIsOpen else { return }
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

  /// Browsing away pauses playback; returning never starts audio implicitly.
  @discardableResult
  func pauseForNavigation() -> Bool {
    guard isActive, !isPaused else { return false }
    player.pause()
    refresh()
    return true
  }

}

// MARK: - Overlay

struct InlinePlayerChrome: View {
  @ObservedObject var model: InlinePlayerModel
  var details: AnyView? = nil
  @State private var detailsPresented = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var volumePresented = false
  @FocusState private var focusedControl: Bool
  @AccessibilityFocusState private var accessibleControl: Bool
  @State private var scrubbing = false
  @State private var scrubValue: Double = 0

  private var displayedPosition: Double {
    scrubbing ? scrubValue : model.position
  }

  var body: some View {
    ZStack {
      if let message = model.loadingMessage { InlineLoadingIndicator(message: message) }
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
    .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
      model.holdControlsForMenu(true)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
      model.holdControlsForMenu(volumePresented || detailsPresented)
    }
    .onChange(of: focusedControl) { _, focused in model.holdControlsForFocus(focused || accessibleControl) }
    .onChange(of: accessibleControl) { _, focused in model.holdControlsForFocus(focused || focusedControl) }
  }

  private var controls: some View {
    VStack(spacing: Tokens.HUD.controlSpacing) {
      timeline
      transport
    }
    .padding(.horizontal, Tokens.HUD.bottomMargin)
    .padding(.vertical, Tokens.HUD.controlSpacing)
    .padding(.bottom, Tokens.HUD.timelineBottom)
    .frame(maxWidth: Tokens.Library.transportMaximumWidth)
    .padding(.horizontal, Tokens.Space.n16)
    .onChange(of: volumePresented) { _, _ in model.holdControlsForMenu(volumePresented || detailsPresented) }
    .onChange(of: detailsPresented) { _, _ in model.holdControlsForMenu(volumePresented || detailsPresented) }
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
        .shadow(color: Tokens.Palette.black.color, radius: Tokens.Space.n2)

      InlineSlider(
        value: Binding(
          get: { displayedPosition },
          set: { value in
            if scrubbing { scrubValue = value } else { model.seek(to: value) }
          }),
        range: 0...max(model.duration, 1),
        label: inlineL("Playback position"), onEditingChanged: { editing in
          if editing { scrubbing = true; scrubValue = model.position }
          else { scrubbing = false; model.seek(to: scrubValue) }
        }, onFocusChanged: { model.holdControlsForFocus($0) })
        .disabled(model.duration <= 0)
        .focused($focusedControl)
        .accessibilityFocused($accessibleControl)

      Text(model.duration > 0 ? VideoTime(model.duration).stringRepresentation : inlineL("Live"))
        .font(Tokens.Typography.numeric.font)
        .foregroundStyle(Tokens.Palette.onMediaSecondary.color)
        .monospacedDigit()
        .shadow(color: Tokens.Palette.black.color, radius: Tokens.Space.n2)
    }
    .padding(.horizontal, Tokens.HUD.timelineHeight)
  }

  // MARK: Transport

  private var transport: some View {
    ZStack {
      playbackButtons
      HStack {
        volumeControl
        Spacer(minLength: Tokens.Space.n8)
        if let details {
          controlButton("info.circle", label: inlineL("Details")) { detailsPresented.toggle() }
            .popover(isPresented: $detailsPresented) { details }
        }
        utilityButtons
        fullscreenButton
      }
    }
    .padding(.horizontal, Tokens.Space.n8)
  }

  private var playbackButtons: some View {
    HStack(spacing: Tokens.Space.n8) {
      controlButton("gobackward.15", label: inlineL("Back 15 Seconds")) { model.skip(by: -15) }
      Button { model.togglePlayPause() } label: {
        Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
          .font(Tokens.Typography.sectionTitle.font)
          .frame(width: Tokens.Library.playControlSize, height: Tokens.Library.playControlSize)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .foregroundStyle(Tokens.Palette.onMedia.color)
      .accessibilityLabel(model.isPaused ? inlineL("Play") : inlineL("Pause"))
      .help(model.isPaused ? inlineL("Play") : inlineL("Pause"))
      .focused($focusedControl)
      .accessibilityFocused($accessibleControl)
      controlButton("goforward.15", label: inlineL("Forward 15 Seconds")) { model.skip(by: 15) }
    }
  }

  private var utilityButtons: some View {
    Menu {
      audioMenu
      subtitleMenu
      speedMenu
      Button(inlineL("Open in New Window")) { model.onOpenInNewWindow?() }
    } label: {
      Image(systemName: "ellipsis")
        .frame(width: Tokens.Library.glassControlSize, height: Tokens.Library.glassControlSize)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .frame(width: Tokens.Library.glassControlSize, height: Tokens.Library.glassControlSize)
    .glassEffect(.regular.interactive(), in: .circle)
    .foregroundStyle(Tokens.Palette.onMedia.color)
    .tint(Tokens.Palette.onMedia.color)
    .accessibilityLabel(inlineL("Playback Options"))
    .help(inlineL("Playback Options"))
    .focused($focusedControl)
    .accessibilityFocused($accessibleControl)
  }

  private var volumeControl: some View {
    Button { volumePresented.toggle() } label: {
      Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .frame(width: Tokens.Library.glassControlSize, height: Tokens.Library.glassControlSize)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .circle)
    .foregroundStyle(Tokens.Palette.onMedia.color)
    .accessibilityLabel(inlineL("Volume"))
    .help(inlineL("Volume"))
    .focused($focusedControl)
    .accessibilityFocused($accessibleControl)
    .popover(isPresented: $volumePresented) {
      HStack(spacing: Tokens.Space.n12) {
        Button(model.isMuted ? inlineL("Unmute") : inlineL("Mute")) { model.toggleMute() }
        InlineSlider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }),
          range: 0...Double(Preference.integer(for: .maxVolume)), label: inlineL("Volume"),
          onFocusChanged: { model.holdControlsForFocus($0) })
          .frame(width: Tokens.Size.n180)
      }.padding(Tokens.Space.n16)
    }
  }

  private var fullscreenButton: some View {
    controlButton(model.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                  label: model.isFullscreen ? inlineL("Exit Full Screen") : inlineL("Enter Full Screen")) {
      model.toggleFullscreen()
    }
  }

  private func controlButton(_ symbol: String, label: String,
                             action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(Tokens.Typography.body.font)
        .frame(width: Tokens.Library.glassControlSize, height: Tokens.Library.glassControlSize)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .circle)
    .foregroundStyle(Tokens.Palette.onMedia.color)
    .accessibilityLabel(label)
    .help(label)
    .focused($focusedControl)
    .accessibilityFocused($accessibleControl)
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
    .disabled(model.audioTracks.isEmpty)
    .help(model.audioTracks.isEmpty ? inlineL("No Audio Tracks") : inlineL("Audio Track"))
    .tint(Tokens.Palette.onMedia.color)
    .focused($focusedControl)
    .accessibilityFocused($accessibleControl)
  }

  private var subtitleMenu: some View {
    Menu {
      Button { model.selectSubtitle(MPVTrack.noneSubTrack) } label: {
        if model.selectedSubID == nil || model.selectedSubID == 0 {
          Label(inlineL("Off"), systemImage: "checkmark")
        } else { Text(inlineL("Off")) }
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
    .help(inlineL("Subtitles"))
    .tint(Tokens.Palette.onMedia.color)
    .focused($focusedControl)
    .accessibilityFocused($accessibleControl)
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
    .help(inlineL("Playback Speed"))
    .tint(Tokens.Palette.onMedia.color)
    .focused($focusedControl)
    .accessibilityFocused($accessibleControl)
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
struct InlineSlider: NSViewRepresentable {
  @Binding var value: Double
  let range: ClosedRange<Double>
  let label: String
  var onEditingChanged: (Bool) -> Void = { _ in }
  var onFocusChanged: (Bool) -> Void = { _ in }

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
    slider.onFocusChanged = { [weak coordinator = context.coordinator] focused in
      coordinator?.parent.onFocusChanged(focused)
    }
    context.coordinator.slider = slider
    return slider
  }

  func updateNSView(_ nsView: SliderView, context: Context) {
    context.coordinator.parent = self
    nsView.minValue = range.lowerBound
    nsView.maxValue = range.upperBound
    nsView.setAccessibilityLabel(label)
    if !nsView.isDragging {
      nsView.doubleValue = value
    }
  }

  final class Coordinator: NSObject {
    var parent: InlineSlider
    weak var slider: SliderView?

    init(_ parent: InlineSlider) { self.parent = parent }

    @objc func valueChanged(_ sender: NSSlider) {
      parent.value = sender.doubleValue
    }
  }

  final class SliderView: NSSlider {
    var onEditingChanged: ((Bool) -> Void)?
    private(set) var isDragging = false
    var onFocusChanged: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
      let accepted = super.becomeFirstResponder()
      if accepted { onFocusChanged?(true) }
      return accepted
    }

    override func resignFirstResponder() -> Bool {
      let accepted = super.resignFirstResponder()
      if accepted { onFocusChanged?(false) }
      return accepted
    }

    override func mouseDown(with event: NSEvent) {
      isDragging = true
      onEditingChanged?(true)
      super.mouseDown(with: event)
      isDragging = false
      onEditingChanged?(false)
    }
  }
}
