package msg

import "core:os"
import "core:strings"

import "jm:i18n"
import "jm:path"

// LOCALE_FILE is the saved BCP 47 tag, one line, beside review and sync.
LOCALE_FILE :: "locale"

// config_dir is ~/.config/brain, or $XDG_CONFIG_HOME/brain when that is set.
// The desk reads it from the process environment. The CLI passes its own
// conf_dir, which honours a test's overrides, into startup_locale instead.
config_dir :: proc(allocator := context.allocator) -> string {
	if xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); xdg != "" {
		return path.join(xdg, "brain", allocator = allocator)
	}
	return path.join(path.home(context.temp_allocator), ".config", "brain", allocator = allocator)
}

// read_tag is the saved tag, or not found when the file is missing or blank.
read_tag :: proc(conf: string, allocator := context.allocator) -> (tag: string, found: bool) {
	if conf == "" {
		return "", false
	}
	text, err := path.read(path.join(conf, LOCALE_FILE, allocator = context.temp_allocator), context.temp_allocator)
	if err != nil {
		return "", false
	}
	tag = strings.trim_space(text)
	if tag == "" {
		return "", false
	}
	return strings.clone(tag, allocator), true
}

// save_tag writes locale's tag where the next desk start and the CLI read it.
save_tag :: proc(conf: string, locale: i18n.Locale) -> bool {
	if conf == "" {
		return false
	}
	body := strings.concatenate({i18n.locale_tag(locale), "\n"}, context.temp_allocator)
	return path.write(path.join(conf, LOCALE_FILE, allocator = context.temp_allocator), body) == nil
}

// startup_locale is the language to open in: the saved tag, else the first
// of system that names a language we ship, else English. system is LC_ALL,
// LC_MESSAGES, LANG, the order POSIX gives them.
startup_locale :: proc(conf: string, system: []string) -> i18n.Locale {
	if tag, found := read_tag(conf, context.temp_allocator); found {
		if locale, ok := i18n.locale_match(tag); ok && shipped(locale) {
			return locale
		}
	}
	for tag in system {
		if locale, ok := i18n.locale_match(tag); ok && shipped(locale) {
			return locale
		}
	}
	return .English
}

// system_tags is LC_ALL, LC_MESSAGES and LANG from the process environment.
system_tags :: proc(allocator := context.temp_allocator) -> []string {
	keys := [?]string{"LC_ALL", "LC_MESSAGES", "LANG"}
	out := make([]string, len(keys), allocator)
	for key, i in keys {
		out[i] = os.get_env(key, allocator)
	}
	return out
}
