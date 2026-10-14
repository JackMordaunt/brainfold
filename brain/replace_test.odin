#+build !windows
package brain

import "core:os"
import "core:testing"

import "jm:path"

// An open reader keeps the bytes it already has. A later open sees the
// new file, and the path is never missing in between.
@(test)
replace_file_leaves_an_open_reader_its_bytes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, err := path.temp_dir("brain-replace-")
	testing.expect_value(t, err, nil)
	defer os.remove_all(dir)

	dst := path.join(dir, "brain.db")
	src := path.join(dir, "brain.db.new")
	testing.expect_value(t, path.write(dst, "old"), nil)
	testing.expect_value(t, path.write(src, "new"), nil)
	held, oerr := os.open(dst)
	testing.expect_value(t, oerr, nil)
	defer os.close(held)

	testing.expect_value(t, replace_file(src, dst), "")
	buf := [3]byte{}
	n, rerr := os.read(held, buf[:])
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, string(buf[:]), "old")
	got, _ := path.read(dst, context.temp_allocator)
	testing.expect_value(t, got, "new")
}
