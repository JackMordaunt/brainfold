#+build !windows
package brain

import "core:fmt"
import "core:os"

// replace_file moves src over dst, which may exist. rename replaces in
// one step, so a reader never finds dst missing, and a handle opened
// before the swap keeps the bytes it already had. The Windows half waits
// when a reader still has dst open.
replace_file :: proc(src, dst: string) -> string {
	if err := os.rename(src, dst); err != nil {
		os.remove(src)
		return fmt.aprintf("cannot replace %s: %v", dst, err)
	}
	return ""
}
