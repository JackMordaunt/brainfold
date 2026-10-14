package msg

import "core:os"
import "core:testing"

import "jm:i18n"
import "jm:path"

@(test)
test_every_locale_translates_every_message :: proc(t: ^testing.T) {
	base: i18n.Table(Msg)
	err, line := i18n.load(&base, .English, SOURCES[.English])
	testing.expectf(t, err == .None, "en.txt line %d: %v", line, err)
	defer free_all(context.temp_allocator)
	for locale in i18n.Locale {
		if !shipped(locale) {
			continue
		}
		for issue in i18n.check(Msg, locale, SOURCES[locale], &base, context.temp_allocator) {
			testing.expectf(t, false, "%s: %v", i18n.locale_tag(locale), issue)
		}
	}
}

@(test)
test_every_known_locale_ships :: proc(t: ^testing.T) {
	for locale in i18n.Locale {
		testing.expectf(t, shipped(locale), "%s has no locales/%s.txt", i18n.locale_english(locale), i18n.locale_tag(locale))
	}
}

@(test)
test_a_missing_message_fails_the_check :: proc(t: ^testing.T) {
	base: i18n.Table(Msg)
	err, line := i18n.load(&base, .English, SOURCES[.English])
	testing.expectf(t, err == .None, "en.txt line %d: %v", line, err)
	defer free_all(context.temp_allocator)
	issues := i18n.check(Msg, .German, "save = Speichern\n", &base, context.temp_allocator)
	missing := false
	for issue in issues {
		if issue.kind == .Missing {
			missing = true
		}
	}
	testing.expect(t, missing)
}

@(test)
test_use_switches_and_formats_in_the_locale :: proc(t: ^testing.T) {
	s: Strings
	init(&s, .English)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, tr(&s, .Save), "Save")
	testing.expect_value(t, trf(&s, .Sessions, 2), "2 sessions")
	use(&s, .German)
	testing.expect_value(t, locale(&s), i18n.Locale.German)
	testing.expect_value(t, tr(&s, .Save), "Speichern")
	testing.expect_value(t, trf(&s, .Sessions, 1), "1 Sitzung")
	testing.expect_value(t, trf(&s, .Sessions, 2), "2 Sitzungen")
	use(&s, .French)
	testing.expect_value(t, trf(&s, .Sessions, 0), "0 session")
	testing.expect_value(t, trf(&s, .Sessions, 2), "2 sessions")
	use(&s, .Arabic)
	testing.expect(t, tr(&s, .Save) != "Save")
}

@(test)
test_startup_locale_prefers_the_saved_tag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir, err := path.temp_dir("msg-locale-")
	testing.expect_value(t, err, nil)
	defer {
		os.remove_all(dir)
		delete(dir)
	}
	testing.expect(t, save_tag(dir, .Japanese))
	testing.expect_value(t, startup_locale(dir, {"fr_FR.UTF-8"}), i18n.Locale.Japanese)
	empty, err2 := path.temp_dir("msg-locale-")
	testing.expect_value(t, err2, nil)
	defer {
		os.remove_all(empty)
		delete(empty)
	}
	testing.expect_value(t, startup_locale(empty, {"fr_FR.UTF-8"}), i18n.Locale.French)
	testing.expect_value(t, startup_locale(empty, {"C", "POSIX"}), i18n.Locale.English)
	testing.expect_value(t, startup_locale("", {"pt_BR.UTF-8"}), i18n.Locale.Portuguese_Brazil)
}
