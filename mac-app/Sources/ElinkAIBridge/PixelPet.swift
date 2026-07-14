import SwiftUI

// 像素吉祥物：'#' 为主体色，'E' 为眼睛，'.' 为透明
enum PixelPet {
    // Claude Code 的 Clawd 小螃蟹
    static let claude = [
        "..##########..",
        ".############.",
        ".###E####E###.",
        ".###E####E###.",
        "##############",
        "##############",
        ".############.",
        ".############.",
        "..#.#....#.#..",
        "..#.#....#.#..",
    ]

    // Codex CLI 官方吉祥物 Froge 青蛙
    static let codex = [
        ".##........##.",
        ".#E#......#E#.",
        ".############.",
        "##############",
        "##############",
        "##############",
        ".############.",
        "..###....###..",
    ]
}

struct PixelPetView: View {
    let art: [String]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let rows = art.count
            let cols = art.first?.count ?? 1
            let cell = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
            let xOffset = (size.width - cell * CGFloat(cols)) / 2
            let yOffset = (size.height - cell * CGFloat(rows)) / 2
            for (y, row) in art.enumerated() {
                for (x, char) in row.enumerated() {
                    guard char != "." else { continue }
                    let rect = CGRect(x: xOffset + CGFloat(x) * cell,
                                      y: yOffset + CGFloat(y) * cell,
                                      width: cell + 0.4, height: cell + 0.4)
                    let fill = char == "E" ? Color(red: 0.08, green: 0.08, blue: 0.10) : color
                    context.fill(Path(rect), with: .color(fill))
                }
            }
        }
    }
}
