import Foundation

/// Finds the current directory of the interactive shell behind our PTY, from a second exec channel of the same
/// connection. The PTY request carries a marker environment variable (`environmentNames`, the session's UUID):
/// sshd accepts only names listed in AcceptEnv, and Debian/Ubuntu/macOS accept `LC_*` out of the box. The probe
/// looks for the process holding the marker, then reads the cwd of the terminal's foreground process (falling back
/// to the shell's own): Linux through /proc, macOS through ps -E and lsof. Without the marker (env refused), Linux
/// takes the newest terminal session sshd started for this user. Only the login user's own processes count.
public enum ShellProbe {
    /// Sent on the PTY request, each with the marker as its value; a refused one is ignored.
    public static let environmentNames = ["LC_RSSH_SESSION", "RSSH_SESSION"]

    /// The script for `marker`, or nil when the marker is not a plain id (it is pasted into the script).
    public static func script(marker: String) -> String? {
        guard !marker.isEmpty, marker.count <= 64,
              marker.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) })
        else { return nil }
        return template.replacingOccurrences(of: "@MARKER@", with: marker)
    }

    /// The directory the script printed (`cwd:/path`), or nil.
    public static func directory(fromOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline).reversed()
            .first { $0.hasPrefix("cwd:/") }
            .map { String($0.dropFirst(4)) }
    }

    static let template = #"""
    k='@MARKER@'; m="RSSH_SESSION=$k"; shell=''; d=''
    st() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null; }
    if [ -d /proc/self ]; then
      pids=" $(grep -l -a -e "$m" /proc/[0-9]*/environ 2>/dev/null | sed 's#^/proc/##;s#/environ$##' | tr '\n' ' ') "
      for p in $pids; do
        [ -O "/proc/$p" ] || continue
        pp=$(st "$p" | cut -d' ' -f2)
        case "$pids" in *" $pp "*) ;; *) shell=$p; break ;; esac
      done
      if [ -z "$shell" ]; then
        best=0
        for s in /proc/[0-9]*/stat; do
          p=${s#/proc/}; p=${p%/stat}
          [ -O "/proc/$p" ] || continue
          f=$(st "$p") || continue
          set -- $f
          [ "$5" != 0 ] || continue
          case "$(cat "/proc/$2/comm" 2>/dev/null)" in sshd*) ;; *) continue ;; esac
          if [ "${20}" -gt "$best" ]; then best=${20}; shell=$p; fi
        done
      fi
      if [ -n "$shell" ]; then
        fg=$(st "$shell" | cut -d' ' -f6)
        d=$(readlink "/proc/$fg/cwd" 2>/dev/null) || d=''
        [ -n "$d" ] || d=$(readlink "/proc/$shell/cwd" 2>/dev/null)
      fi
    else
      shell=$(ps -wwE -U "$(id -u)" -o pid= -o comm= -o command= 2>/dev/null |
        awk -v m="$m" 'index($0, m) && $2 !~ /(^|\/)(awk|grep|ps)$/ { print $1; exit }')
      if [ -n "$shell" ]; then
        fg=$(ps -o tpgid= -p "$shell" 2>/dev/null | tr -d ' ')
        for p in $fg $shell; do
          d=$(lsof -a -d cwd -p "$p" -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
          [ -n "$d" ] && break
        done
      fi
    fi
    case "$d" in /*) printf 'cwd:%s\n' "$d" ;; esac
    exit 0
    """#
}
