#+build windows
package brain

import "core:strings"
import win32 "core:sys/windows"

// start_detached starts argv as a process of its own and returns at once.
// It calls CreateProcess itself rather than `start /b` through cmd: cmd
// handed the child its own standard handles, the caller's capture pipes,
// so the caller waited out the timeout; and cmd took the backslashed quotes
// of the argv it was given as literal text, so the child never started
// (CI run 37959889988).
// This child inherits no handles, has no console and a process group of
// its own, and leaves the caller's job where the job allows it.
start_detached :: proc(argv: []string, dir: string, env: []string) {
	line := strings.builder_make(context.temp_allocator)
	for arg, i in argv {
		if i > 0 {
			strings.write_byte(&line, ' ')
		}
		// The arguments are an executable's path and plain flags; a
		// Windows path cannot hold a quote (a reserved character in Win32
		// file names), so quoting each is enough.
		strings.write_byte(&line, '"')
		strings.write_string(&line, arg)
		strings.write_byte(&line, '"')
	}
	// KEY=VALUE, each ended by a NUL; the conversion adds the final one.
	block := strings.builder_make(context.temp_allocator)
	for kv in env {
		strings.write_string(&block, kv)
		strings.write_byte(&block, 0)
	}
	line_w := win32.utf8_to_wstring(strings.to_string(line), context.temp_allocator)
	block_w := win32.utf8_to_utf16(strings.to_string(block), context.temp_allocator)
	dir_w := win32.utf8_to_wstring(dir, context.temp_allocator)
	flags: win32.DWORD = win32.CREATE_UNICODE_ENVIRONMENT | win32.DETACHED_PROCESS | win32.CREATE_NEW_PROCESS_GROUP
	start := win32.STARTUPINFOW {
		cb = size_of(win32.STARTUPINFOW),
	}
	info: win32.PROCESS_INFORMATION
	ok := win32.CreateProcessW(nil, line_w, nil, nil, false, flags | win32.CREATE_BREAKAWAY_FROM_JOB, raw_data(block_w), dir_w, &start, &info)
	if !ok {
		// A job that forbids breaking away refuses the whole call.
		ok = win32.CreateProcessW(nil, line_w, nil, nil, false, flags, raw_data(block_w), dir_w, &start, &info)
	}
	if ok {
		win32.CloseHandle(info.hProcess)
		win32.CloseHandle(info.hThread)
	}
}

// leave_session has nothing to do on Windows: start_detached already gave
// the child a process group of its own.
leave_session :: proc() {}
