//
//  HistogramView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Live RGB histogram — red, green, and blue channels screen-blended over a
//  dark plot (the pro-editor look). The Adjust panel computes the data as
//  adjustments change and shares it with the Levels and Curves bricks.
//

import SwiftUI

struct HistogramView: View {
    let data: HistogramData

    var body: some View {
        Canvas { context, size in
            // Plot background + thirds grid.
            let plot = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: plot, cornerRadius: 6), with: .color(.black.opacity(0.85)))
            var grid = Path()
            for i in 1..<4 {
                let x = size.width * CGFloat(i) / 4
                grid.move(to: CGPoint(x: x, y: 2))
                grid.addLine(to: CGPoint(x: x, y: size.height - 2))
            }
            context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)

            // Luminance as a faint base, then RGB screen-blended on top.
            context.fill(channelPath(data.luminance, in: size), with: .color(.white.opacity(0.14)))
            context.blendMode = .screen
            context.fill(channelPath(data.red, in: size), with: .color(Color(red: 0.9, green: 0.16, blue: 0.16).opacity(0.75)))
            context.fill(channelPath(data.green, in: size), with: .color(Color(red: 0.16, green: 0.85, blue: 0.3).opacity(0.75)))
            context.fill(channelPath(data.blue, in: size), with: .color(Color(red: 0.25, green: 0.45, blue: 1.0).opacity(0.75)))
        }
        .frame(height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .help("RGB histogram of the adjusted photo — shadows left, highlights right")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RGB tone histogram of the adjusted photo")
    }

    /// A smooth filled mountain for one channel.
    private func channelPath(_ bins: [Double], in size: CGSize) -> Path {
        var path = Path()
        guard bins.count > 1 else { return path }
        let stepX = size.width / CGFloat(bins.count - 1)
        let baseline = size.height - 2

        func point(_ index: Int) -> CGPoint {
            CGPoint(x: CGFloat(index) * stepX,
                    y: baseline - CGFloat(bins[index]) * (size.height - 10))
        }

        path.move(to: CGPoint(x: 0, y: baseline))
        path.addLine(to: point(0))
        for index in 1..<bins.count {
            let previous = point(index - 1)
            let current = point(index)
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: point(bins.count - 1))
        path.addLine(to: CGPoint(x: size.width, y: baseline))
        path.closeSubpath()
        return path
    }
}
