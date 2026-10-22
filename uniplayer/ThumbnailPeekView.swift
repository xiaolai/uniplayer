//
//  ThumbnailPeekView.swift
//  uniplayer
//
//  Created by lhc on 12/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class ThumbnailPeekView: NSView {

  var imageView: NSImageView!

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = Tokens.Radius.n4
    layer?.masksToBounds = true
    layer?.borderWidth = Tokens.Stroke.hairline
    layer?.borderColor = CGColor(gray: 0.6, alpha: 0.5)

    let s = NSShadow()
    s.shadowBlurRadius = Tokens.Blur.n2
    s.shadowColor = Tokens.Palette.black.nsColor
    shadow = s

    imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = Tokens.Radius.n4
    imageView.layer?.masksToBounds = true
    imageView.imageScaling = .scaleAxesIndependently
    addSubview(imageView)
    imageView.padding(.all(Tokens.Space.n0))
  }

}
