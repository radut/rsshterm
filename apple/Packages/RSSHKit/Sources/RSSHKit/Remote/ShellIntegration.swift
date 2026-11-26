import Foundation

/// The optional shell hook that reports the current folder with OSC 7, so uploads land where the user is without
/// probing. Shown in Settings; written to the server's rc files only when the user taps Install.
public enum ShellIntegration {
    /// Marks the installed line, so Install does not add it twice.
    public static let tag = "# rsshterm-osc7"

    public static let bashHook =
        #"PROMPT_COMMAND='printf "\033]7;file://%s%s\033\\" "${HOSTNAME:-}" "$PWD"'"${PROMPT_COMMAND:+;$PROMPT_COMMAND}""#

    public static let zshHook =
        #"_rssh_osc7() { printf '\033]7;file://%s%s\033\\' "${HOST:-}" "$PWD"; }; autoload -Uz add-zsh-hook && add-zsh-hook precmd _rssh_osc7"#

    /// Appends each hook to its rc file unless the tag is there already; zsh only when ~/.zshrc exists or the login
    /// shell is zsh. Prints what it did.
    public static var installCommand: String {
        [append(bashHook, to: "~/.bashrc", when: nil),
         append(zshHook, to: "~/.zshrc", when: #"[ -f ~/.zshrc ] || [ "${SHELL##*/}" = zsh ]"#)]
            .joined(separator: "; ") + "; exit 0"
    }

    private static func append(_ hook: String, to file: String, when condition: String?) -> String {
        let line = RemotePath.shellQuoted(hook + " " + tag)
        let body = "if grep -qF \(RemotePath.shellQuoted(tag)) \(file) 2>/dev/null; then echo \"\(file): already there\"; "
            + "else printf '%s\\n' \(line) >> \(file) && echo \"\(file): added\"; fi"
        guard let condition else { return body }
        return "if \(condition); then \(body); fi"
    }

    // MARK: tab titles

    /// Marks the installed tab-title snippet (it includes the OSC 7 hook).
    public static let titlesTag = "# rsshterm-titles"

    /// bash (4.4+, for PS0): the folder (OSC 7), prompt and command marks (OSC 133 A/C/D) and the titles a tab
    /// reads: `user@host: folder` at the prompt, `user@host › command line` while a command runs
    /// (`TerminalTitleParser`). Guarded, so sourcing it twice changes nothing.
    public static let bashTitles = #"""
    if [ -n "${BASH_VERSION:-}" ] && [ -z "${_RSSH_TITLES:-}" ]; then
      _RSSH_TITLES=1
      _rssh_host=${HOSTNAME%%.*}
      _rssh_precmd() {
        local s=$?
        printf '\033]133;D;%s\033\\\033]7;file://%s%s\033\\\033]2;%s@%s: %s\033\\\033]133;A\033\\' \
          "$s" "${HOSTNAME:-}" "$PWD" "${USER:-$(id -un)}" "$_rssh_host" "${PWD/#$HOME/\~}"
        return $s
      }
      _rssh_ps0() {
        local c
        c=$(HISTTIMEFORMAT= builtin history 1)
        c=${c#*[0-9]*  }
        printf '\033]133;C\033\\\033]2;%s@%s › %s\033\\' "${USER:-$(id -un)}" "$_rssh_host" "${c//[[:cntrl:]]/ }"
      }
      PROMPT_COMMAND="_rssh_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
      PS0='$(_rssh_ps0)'"${PS0:-}"
    fi
    """#

    /// zsh: the same reports from precmd/preexec hooks.
    public static let zshTitles = #"""
    if [ -n "${ZSH_VERSION:-}" ] && [ -z "${_RSSH_TITLES:-}" ]; then
      _RSSH_TITLES=1
      _rssh_precmd() {
        local s=$?
        printf '\033]133;D;%s\033\\\033]7;file://%s%s\033\\\033]2;%s@%s: %s\033\\\033]133;A\033\\' \
          "$s" "${HOST:-}" "$PWD" "${USER:-$(id -un)}" "${HOST%%.*}" "${(%):-%~}"
      }
      _rssh_preexec() {
        printf '\033]133;C\033\\\033]2;%s@%s › %s\033\\' "${USER:-$(id -un)}" "${HOST%%.*}" "${1//[[:cntrl:]]/ }"
      }
      autoload -Uz add-zsh-hook
      add-zsh-hook precmd _rssh_precmd
      add-zsh-hook preexec _rssh_preexec
    fi
    """#

    /// fish: its own title hook says the same, plus OSC 7 and OSC 133 on its events.
    public static let fishTitles = #"""
    if not set -q _RSSH_TITLES
      set -g _RSSH_TITLES 1
      function fish_title
        if set -q argv[1]
          echo "$USER@"(prompt_hostname)" › "(string replace -ra '[[:cntrl:]]' ' ' -- $argv[1])
        else
          echo "$USER@"(prompt_hostname)": "(prompt_pwd)
        end
      end
      function _rssh_prompt --on-event fish_prompt
        printf '\e]133;D;%s\e\\\\\e]7;file://%s%s\e\\\\\e]133;A\e\\\\' $status (hostname) $PWD
      end
      function _rssh_preexec --on-event fish_preexec
        printf '\e]133;C\e\\\\'
      end
    end
    """#

    /// Where each snippet goes.
    public static let titleTargets: [(shell: String, file: String, snippet: String)] = [
        ("bash", "~/.bashrc", bashTitles),
        ("zsh", "~/.zshrc", zshTitles),
        ("fish", "~/.config/fish/conf.d/rsshterm.fish", fishTitles),
    ]

    /// Appends each snippet to its rc file unless the titles tag is there; zsh and fish only when that shell is
    /// the login shell or its config exists. Prints what it did. Idempotent.
    public static var installTitlesCommand: String {
        titleTargets.map { target -> String in
            let body = appendBlock(target.snippet, to: target.file)
            switch target.shell {
            case "bash": return body
            case "zsh": return #"if [ -f ~/.zshrc ] || [ "${SHELL##*/}" = zsh ]; then "# + body + "; fi"
            default:
                return #"if [ -d ~/.config/fish ] || [ "${SHELL##*/}" = fish ]; then mkdir -p ~/.config/fish/conf.d && "#
                    + body + "; fi"
            }
        }.joined(separator: "; ") + "; exit 0"
    }

    private static func appendBlock(_ snippet: String, to file: String) -> String {
        let block = RemotePath.shellQuoted("\n" + titlesTag + "\n" + snippet + "\n")
        return "if grep -qF \(RemotePath.shellQuoted(titlesTag)) \(file) 2>/dev/null; then echo \"\(file): already there\"; "
            + "else printf '%s' \(block) >> \(file) && echo \"\(file): added\"; fi"
    }
}
