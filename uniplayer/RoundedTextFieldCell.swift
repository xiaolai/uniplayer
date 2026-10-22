//
//  RoundedTextFieldCell.swift
//  uniplayer
//
//  Created by lhc on 12/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

class RoundedTextFieldCell: NSTextFieldCell {

  let paddingH = Tokens.Space.n4
  let paddingV = Tokens.Space.n2

  override func awakeFromNib() {
    bezelStyle = .roundedBezel
  }

  override func drawingRect(forBounds rect: NSRect) -> NSRect {
    return super.drawingRect(forBounds: rect)
  }

}
