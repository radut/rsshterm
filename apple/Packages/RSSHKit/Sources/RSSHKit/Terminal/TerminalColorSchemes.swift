import Foundation

/// The themes in Settings › Terminal › Themes. Values are the palettes as their authors publish them.
public enum TerminalColorSchemes {
    public static let defaultDark = TerminalColorScheme(
        id: "default-dark", name: "Default Dark", isDark: true,
        background: "#000000", foreground: "#D8DEE6", cursor: "#7FB4FF", selection: "#2D3A4D",
        ansi: ["#1B1F24", "#E5534B", "#57AB5A", "#C69026", "#539BF5", "#B083F0", "#39C5CF", "#ADBAC7",
               "#545D68", "#FF938A", "#6BC46D", "#DAAA3F", "#6CB6FF", "#DCBDFB", "#56D4DD", "#EDF1F5"],
        source: "rSshTerm")

    public static let defaultLight = TerminalColorScheme(
        id: "default-light", name: "Default Light", isDark: false,
        background: "#FAFBFC", foreground: "#24292F", cursor: "#0969DA", selection: "#C8DCF5",
        ansi: ["#24292F", "#CF222E", "#116329", "#7D4E00", "#0969DA", "#8250DF", "#1B7C83", "#6E7781",
               "#57606A", "#A40E26", "#1A7F37", "#633C01", "#218BFF", "#A475F9", "#3192AA", "#8C959F"],
        source: "rSshTerm")

    /// Every theme, dark ones first, each group in name order as shown.
    public static let all: [TerminalColorScheme] = [defaultDark, defaultLight] + community

    public static var dark: [TerminalColorScheme] { all.filter(\.isDark) }
    public static var light: [TerminalColorScheme] { all.filter { !$0.isDark } }

    public static func scheme(id: String) -> TerminalColorScheme? { all.first { $0.id == id } }

    private static let solarizedANSI = [
        "#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
        "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]
    private static let catppuccin = "Catppuccin, github.com/catppuccin/catppuccin (MIT)"
    private static let gruvbox = "gruvbox by Pavel Pertsev, github.com/morhetz/gruvbox (MIT)"
    private static let solarized = "Solarized by Ethan Schoonover, ethanschoonover.com/solarized (MIT)"
    private static let github = "GitHub Primer, github.com/primer/github-vscode-theme (MIT)"

    static let community: [TerminalColorScheme] = [
        TerminalColorScheme(
            id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
            background: "#1E1E2E", foreground: "#CDD6F4", cursor: "#F5E0DC", selection: "#585B70",
            ansi: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                   "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"],
            source: catppuccin),
        TerminalColorScheme(
            id: "dracula", name: "Dracula", isDark: true,
            background: "#282A36", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#44475A",
            ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                   "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"],
            source: "Dracula, draculatheme.com (MIT)"),
        TerminalColorScheme(
            id: "github-dark", name: "GitHub Dark", isDark: true,
            background: "#0D1117", foreground: "#E6EDF3", cursor: "#2F81F7", selection: "#264F78",
            ansi: ["#484F58", "#FF7B72", "#3FB950", "#D29922", "#58A6FF", "#BC8CFF", "#39C5CF", "#B1BAC4",
                   "#6E7681", "#FFA198", "#56D364", "#E3B341", "#79C0FF", "#D2A8FF", "#56D4DD", "#FFFFFF"],
            source: github),
        TerminalColorScheme(
            id: "gruvbox-dark", name: "Gruvbox Dark", isDark: true,
            background: "#282828", foreground: "#EBDBB2", cursor: "#EBDBB2", selection: "#504945",
            ansi: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
                   "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"],
            source: gruvbox),
        TerminalColorScheme(
            id: "monokai", name: "Monokai", isDark: true,
            background: "#272822", foreground: "#F8F8F2", cursor: "#F8F8F0", selection: "#49483E",
            ansi: ["#272822", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F8F8F2",
                   "#75715E", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F9F8F5"],
            source: "Monokai by Wimer Hazenberg, base16 port, github.com/chriskempson/base16 (MIT)"),
        TerminalColorScheme(
            id: "nord", name: "Nord", isDark: true,
            background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selection: "#434C5E",
            ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                   "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"],
            source: "Nord by Arctic Ice Studio, nordtheme.com (MIT)"),
        TerminalColorScheme(
            id: "one-dark", name: "One Dark", isDark: true,
            background: "#282C34", foreground: "#ABB2BF", cursor: "#528BFF", selection: "#3E4451",
            ansi: ["#282C34", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
                   "#5C6370", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF"],
            source: "One Dark, Atom, github.com/atom/atom (MIT)"),
        TerminalColorScheme(
            id: "solarized-dark", name: "Solarized Dark", isDark: true,
            background: "#002B36", foreground: "#839496", cursor: "#93A1A1", selection: "#073642",
            ansi: solarizedANSI, source: solarized),
        TerminalColorScheme(
            id: "tokyo-night", name: "Tokyo Night", isDark: true,
            background: "#1A1B26", foreground: "#C0CAF5", cursor: "#C0CAF5", selection: "#283457",
            ansi: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
                   "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"],
            source: "Tokyo Night by enkia, github.com/folke/tokyonight.nvim (Apache 2.0)"),
        TerminalColorScheme(
            id: "tomorrow-night", name: "Tomorrow Night", isDark: true,
            background: "#1D1F21", foreground: "#C5C8C6", cursor: "#C5C8C6", selection: "#373B41",
            ansi: ["#1D1F21", "#CC6666", "#B5BD68", "#F0C674", "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
                   "#969896", "#CC6666", "#B5BD68", "#F0C674", "#81A2BE", "#B294BB", "#8ABEB7", "#FFFFFF"],
            source: "Tomorrow by Chris Kempson, github.com/chriskempson/tomorrow-theme (MIT)"),
        TerminalColorScheme(
            id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
            background: "#EFF1F5", foreground: "#4C4F69", cursor: "#DC8A78", selection: "#ACB0BE",
            ansi: ["#5C5F77", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#ACB0BE",
                   "#6C6F85", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#BCC0CC"],
            source: catppuccin),
        TerminalColorScheme(
            id: "github-light", name: "GitHub Light", isDark: false,
            background: "#FFFFFF", foreground: "#1F2328", cursor: "#0969DA", selection: "#ADD6FF",
            ansi: ["#24292F", "#CF222E", "#116329", "#4D2D00", "#0969DA", "#8250DF", "#1B7C83", "#6E7781",
                   "#57606A", "#A40E26", "#1A7F37", "#633C01", "#218BFF", "#A475F9", "#3192AA", "#8C959F"],
            source: github),
        TerminalColorScheme(
            id: "gruvbox-light", name: "Gruvbox Light", isDark: false,
            background: "#FBF1C7", foreground: "#3C3836", cursor: "#3C3836", selection: "#D5C4A1",
            ansi: ["#FBF1C7", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#7C6F64",
                   "#928374", "#9D0006", "#79740E", "#B57614", "#076678", "#8F3F71", "#427B58", "#3C3836"],
            source: gruvbox),
        TerminalColorScheme(
            id: "solarized-light", name: "Solarized Light", isDark: false,
            background: "#FDF6E3", foreground: "#657B83", cursor: "#586E75", selection: "#EEE8D5",
            ansi: solarizedANSI, source: solarized),
    ]
}
