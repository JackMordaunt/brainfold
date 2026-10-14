#+build windows
package brain

import "core:fmt"
import "core:io"
import "core:os"
import "core:time"

// replace_file moves src over dst, which may exist. os.rename is
// MoveFileEx REPLACE_EXISTING, one step, so a reader never finds dst
// missing. Windows refuses that replace while another handle has dst
// open: SQLite does not share delete, and the refusal is
// Permission_Denied. The desk's readers open, query and close, so wait
// for the handle rather than removing dst. The remove fails the same
// way, and when it works the name is missing until the new file lands
// (CI run 38604750375).
replace_file :: proc(src, dst: string) -> string {
	deadline := time.time_add(time.now(), BUSY_TIMEOUT)
	for {
		err := os.rename(src, dst)
		if err == nil {
			return ""
		}
		if err != io.Error.Permission_Denied || time.since(deadline) >= 0 {
			os.remove(src)
			return fmt.aprintf("cannot replace %s: %v", dst, err)
		}
		time.sleep(20 * time.Millisecond)
	}
}
