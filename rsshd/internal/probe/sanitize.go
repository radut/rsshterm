package probe

import (
	"strings"
	"unicode"
)

// Mask replaces a secret in arguments the daemon reports.
const Mask = "•••"

// Caps on what a pane reports: a title never needs more.
const (
	MaxArgs   = 32
	MaxArgLen = 256
)

var (
	secretWords = []string{"pass", "pwd", "token", "secret", "key", "auth", "credential", "cookie", "session"}
	// Programs whose -p is a password, not a port. Those in attachedOnly prompt on a bare -p.
	shortPPassword = map[string]bool{"mysql": true, "mariadb": true, "mysqldump": true, "mysqladmin": true,
		"mysqlimport": true, "mysqlshow": true, "mysqlcheck": true, "sshpass": true}
	attachedOnly = map[string]bool{"mysql": true, "mariadb": true, "mysqldump": true, "mysqladmin": true,
		"mysqlimport": true, "mysqlshow": true, "mysqlcheck": true}
	// Programs that run another program: the rules of the inner program apply to the words after it.
	wrappers = map[string]bool{"sudo": true, "doas": true, "env": true, "time": true, "nohup": true, "nice": true,
		"exec": true, "command": true, "builtin": true, "stdbuf": true, "timeout": true, "watch": true,
		"xargs": true, "ionice": true, "chrt": true, "taskset": true, "caffeinate": true}
	// Options of wrappers that take a value (sudo -u root, nice -n 5, timeout -s KILL).
	wrapperValueOptions = map[string]bool{"-u": true, "-g": true, "-n": true, "-s": true, "-k": true, "-C": true,
		"-D": true, "-h": true, "-p": true, "-r": true, "-t": true, "-U": true, "-c": true, "-o": true, "-e": true,
		"-i": true, "-L": true, "-I": true}
	// Options whose value is user:password (curl -u, wget --user).
	userPassOptions = map[string]bool{"-u": true, "--user": true, "--proxy-user": true, "-U": true}
)

// SanitizeArgs takes secrets out of program's arguments: values of password/token/secret/key flags, -p of the
// programs where it is a password, NAME_TOKEN= assignments, user:pass@ in URLs, user:pass of curl -u, secret
// headers and Bearer/Basic credentials. Wrappers (sudo, env, time, ...) pass the rules on to the program they
// run. At most MaxArgs arguments of MaxArgLen bytes each.
func SanitizeArgs(program string, args []string) []string {
	out := make([]string, 0, min(len(args), MaxArgs))
	sanitize(ProgramName(program), args, &out)
	if len(out) > MaxArgs {
		out = out[:MaxArgs]
	}
	for i, a := range out {
		if len(a) > MaxArgLen {
			out[i] = truncate(a, MaxArgLen) + "…"
		}
	}
	return out
}

func sanitize(name string, args []string, out *[]string) {
	name = strings.ToLower(name)
	if wrappers[name] {
		i := 0
	loop:
		for i < len(args) {
			a := args[i]
			switch {
			case a == "--":
				*out = append(*out, a)
				i++
			case strings.HasPrefix(a, "-"):
				*out = append(*out, redactInline(a))
				if wrapperValueOptions[a] && i+1 < len(args) {
					*out = append(*out, args[i+1])
					i++
				}
				i++
				continue
			case isAssignment(a):
				*out = append(*out, redactInline(a))
				i++
				continue
			}
			break loop
		}
		if i < len(args) {
			*out = append(*out, args[i])
			sanitize(ProgramName(args[i]), args[i+1:], out)
		}
		return
	}
	hideNext, userPassNext := false, false
	for _, a := range args {
		switch {
		case hideNext:
			*out = append(*out, Mask)
			hideNext = false
			continue
		case userPassNext:
			*out = append(*out, maskUserPass(a))
			userPassNext = false
			continue
		}
		if shortPPassword[name] && strings.HasPrefix(a, "-p") && !strings.HasPrefix(a, "--") {
			if a == "-p" {
				hideNext = !attachedOnly[name]
				*out = append(*out, a)
			} else {
				*out = append(*out, "-p"+Mask)
			}
			continue
		}
		if strings.HasPrefix(a, "-") {
			if eq := strings.IndexByte(a, '='); eq > 0 {
				flag := a[:eq]
				switch {
				case isSecretName(flag):
					*out = append(*out, flag+"="+Mask)
				case userPassOptions[flag]:
					*out = append(*out, flag+"="+maskUserPass(a[eq+1:]))
				default:
					*out = append(*out, redactInline(a))
				}
				continue
			}
			if isSecretName(a) {
				*out = append(*out, a)
				hideNext = true
				continue
			}
			if userPassOptions[a] && name != "sudo" {
				*out = append(*out, a)
				userPassNext = true
				continue
			}
		}
		*out = append(*out, redactInline(a))
	}
}

func isSecretName(flag string) bool {
	l := strings.ToLower(strings.TrimLeft(flag, "-"))
	if len(l) < 2 || strings.HasSuffix(l, "file") || strings.HasSuffix(l, "path") {
		return false
	}
	for _, w := range secretWords {
		if strings.Contains(l, w) {
			return true
		}
	}
	return false
}

func isAssignment(a string) bool {
	eq := strings.IndexByte(a, '=')
	if eq <= 0 {
		return false
	}
	for _, r := range a[:eq] {
		if !(unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_') {
			return false
		}
	}
	return true
}

// maskUserPass hides the password of "user:password".
func maskUserPass(v string) string {
	if i := strings.IndexByte(v, ':'); i >= 0 {
		return v[:i+1] + Mask
	}
	return v
}

// redactInline handles NAME_TOKEN=value, scheme://user:pass@host, "Header-With-Secret: value", Bearer/Basic.
func redactInline(a string) string {
	if !strings.HasPrefix(a, "-") && isAssignment(a) {
		eq := strings.IndexByte(a, '=')
		if isSecretName(a[:eq]) {
			return a[:eq] + "=" + Mask
		}
	}
	if colon := strings.Index(a, ": "); colon > 0 && !strings.ContainsAny(a[:colon], " /") {
		header := a[:colon]
		if isSecretName(header) || strings.EqualFold(header, "authorization") {
			return header + ": " + Mask
		}
	}
	if i := strings.Index(a, "://"); i >= 0 {
		rest := a[i+3:]
		end := strings.IndexByte(rest, '/')
		if end < 0 {
			end = len(rest)
		}
		auth := rest[:end]
		if at := strings.LastIndexByte(auth, '@'); at >= 0 {
			if c := strings.IndexByte(auth[:at], ':'); c >= 0 {
				a = a[:i+3] + auth[:c+1] + Mask + auth[at:] + rest[end:]
			}
		}
	}
	lower := strings.ToLower(a)
	for _, scheme := range []string{"bearer ", "basic ", "token "} {
		if j := strings.Index(lower, scheme); j >= 0 && j+len(scheme) < len(a) {
			return a[:j+len(scheme)] + Mask
		}
	}
	return a
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8Start(s[n]) {
		n--
	}
	return s[:n]
}

func utf8Start(b byte) bool { return b&0xC0 != 0x80 }
