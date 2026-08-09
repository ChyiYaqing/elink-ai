import AppKit
import SwiftUI
import XCTest
@testable import ElinkAIBridge

final class ThemeTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppTheme.defaultsKey)
        super.tearDown()
    }

    func testThemeSelectionPersistsAndFallsBackToWashi() {
        UserDefaults.standard.removeObject(forKey: AppTheme.defaultsKey)
        XCTAssertEqual(AppTheme.current, .washi, "没选过时用和纸墨")

        AppTheme.current = .violet
        XCTAssertEqual(AppTheme.current, .violet)

        // 降级安装或手改 plist 都可能留下一个已经不存在的主题名，
        // 这时候要回到默认主题而不是让面板没有颜色
        UserDefaults.standard.set("no-such-theme", forKey: AppTheme.defaultsKey)
        XCTAssertEqual(AppTheme.current, .washi)
    }

    /// 新增主题只需实现 PanelPaletteSpec，不改任何视图——代价是没人替我们检查
    /// 新色板是不是填全了。渐变缺停靠点会画成空白，设备色撞色会让两台机器看着像一台。
    func testEveryThemeProvidesACompletePaletteInBothSchemes() {
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                let palette = theme.palette(dark: dark)
                let label = "\(theme.rawValue) dark=\(dark)"

                XCTAssertGreaterThanOrEqual(palette.backgroundStops.count, 2, "\(label) 面板底渐变")
                XCTAssertGreaterThanOrEqual(palette.cardStops.count, 2, "\(label) 卡片渐变")
                XCTAssertGreaterThanOrEqual(palette.accentStops.count, 2, "\(label) 强调渐变")
                XCTAssertEqual(palette.categoryPalette.count, 5, "\(label) 五个 token 分类各要一个色")
                XCTAssertEqual(Set(palette.devicePalette).count, palette.devicePalette.count,
                               "\(label) 设备色位不能重复")
                XCTAssertEqual(Set(palette.dataPalette).count, palette.dataPalette.count,
                               "\(label) 模型色位不能重复")

                // 三个状态色互相撞了，「健康 / 告警 / 超限」在徽章上就只剩文字能区分
                XCTAssertEqual(
                    Set([palette.statusHealthy, palette.statusWarning,
                         palette.statusCritical, palette.statusInfo]).count, 4,
                    "\(label) 状态色必须两两不同")
            }
        }
    }

    /// hover 的填色在两套主题里一深一浅（墨 / 珊瑚），前景色若写死成白色，
    /// 和纸墨的深色模式就会是浅底浅字。前景必须跟着 accent 一起由主题给出。
    func testAccentForegroundDiffersFromAccentFill() {
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                let palette = theme.palette(dark: dark)
                for stop in palette.accentStops {
                    XCTAssertNotEqual(palette.accentForeground, stop,
                                      "\(theme.rawValue) dark=\(dark) hover 前景与填色同色")
                }
            }
        }
    }

    /// 分段控件的选中段由 AppKit 画，文字固定是白的——我们只能选填色。
    /// 「和纸墨」深色模式一度想直接复用砂色，那会变成浅底白字。
    func testControlAccentCarriesWhiteText() {
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                let ratio = Self.contrast(theme.palette(dark: dark).controlAccent, .white)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(theme.rawValue) dark=\(dark) 分段控件选中段白字对比只有 \(ratio)")
            }
        }
    }

    private static func contrast(_ a: Color, _ b: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(srgb.redComponent)
                + 0.7152 * channel(srgb.greenComponent)
                + 0.0722 * channel(srgb.blueComponent)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testSwitchingThemeChangesPanelColors() {
        let washi = PanelTheme(.light, .washi)
        let violet = PanelTheme(.light, .violet)
        XCTAssertNotEqual(washi.textPrimary, violet.textPrimary)
        XCTAssertNotEqual(washi.glassBorder, violet.glassBorder)
        XCTAssertNotEqual(washi.statusHealthy, violet.statusHealthy)
    }

    /// 数据序列色不跟明暗走：同一个模型、同一台设备在浅色和深色面板里必须是
    /// 同一个颜色，否则两块屏幕摆在一起就对不上了。
    func testDataSeriesColorsAreIdenticalAcrossSchemes() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(theme.palette(dark: false).dataPalette,
                           theme.palette(dark: true).dataPalette, theme.rawValue)
            XCTAssertEqual(theme.palette(dark: false).devicePalette,
                           theme.palette(dark: true).devicePalette, theme.rawValue)
            XCTAssertEqual(theme.palette(dark: false).categoryPalette,
                           theme.palette(dark: true).categoryPalette, theme.rawValue)
        }
    }
}
