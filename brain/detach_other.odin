#+build !windows
package brain

import "core:sys/posix"
import "core:time"

import "jm:sh"

// start_detached starts argv in the background and returns at once: sh
// returns as soon as the child is in the background, and the child's
// descriptors are closed or sent to /dev/null, so nothing waits on them.
// The child leaves the caller's session itself (leave_session): the setsid
// command is util-linux's, and macOS has none, so `setsid exe` there ran
// nothing (CI run 37959889988).
start_detached :: proc(argv: []string, dir: string, env: []string) {
	cmd := make([dynamic]string)
	append(&cmd, "sh", "-c", `"$0" "$@" </dev/null >/dev/null 2>&1 &`)
	append(&cmd, ..argv)
	sh.exec(cmd[:], {dir = dir, env = env, timeout = 5 * time.Second})
}

// leave_session puts the background pass in a session of its own, so the
// hangup or kill its starter's process group gets does not end it.
leave_session :: proc() {
	posix.setsid()
}
