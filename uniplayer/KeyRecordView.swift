//
//  KeyRecordView.swift
//  uniplayer
//
//  Created by lhc on 12/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

fileprivate extension NSColor {
  static let keyRecordViewBackground = Tokens.Palette.controlBackground.nsColor.withSystemEffect(.disabled)
  static let keyRecordViewBackgroundActive = Tokens.Palette.controlBackground.nsColor
}

protocol KeyRecordViewDelegate {
  func keyRecordView(_ view: KeyRecordView, recordedKeyDownWith event: NSEvent)
}

class KeyRecordView: NSView {

  var delegate: KeyRecordViewDelegate!

  var currentKey: String = ""
  var currentKeyModifiers: NSEvent.ModifierFlags = []

  override func awakeFromNib() {
    wantsLayer = true
    layer?.backgroundColor = Tokens.Palette.keyRecordBackgroundActive.nsColor.cgColor
    layer?.cornerRadius = Tokens.Radius.n4
  }

  override func updateLayer() {
    layer?.backgroundColor = Tokens.Palette.keyRecordBackgroundActive.nsColor.cgColor
  }
  
  override var acceptsFirstResponder: Bool {
    return true
  }

  override func keyDown(with event: NSEvent) {
    currentKey = event.charactersIgnoringModifiers ?? ""
    currentKeyModifiers = event.modifierFlags
    delegate.keyRecordView(self, recordedKeyDownWith: event)
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }

  override func resignFirstResponder() -> Bool {
    effectiveAppearance.applyAppearanceFor {
      layer?.backgroundColor = Tokens.Palette.keyRecordBackground.nsColor.cgColor
    }
    return true
  }

  override func becomeFirstResponder() -> Bool {
    effectiveAppearance.applyAppearanceFor {
      layer?.backgroundColor = Tokens.Palette.keyRecordBackgroundActive.nsColor.cgColor
    }
    return true
  }
}
