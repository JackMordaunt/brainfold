#+build windows
package brain

import "core:os"
import "core:testing"
import "core:thread"
import "core:time"

import "jm:path"

// os.open shares the way SQLite does: read and write, not delete. The
// swap waits, the path keeps the old bytes the whole time, and it lands
// once that handle closes.
@(test)
replace_file_waits_out_an_open_reader :: proc(t: ^testing.T) {
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

	Job :: struct {
		src, dst, err: string,
	}
	job := Job {
		src = src,
		dst = dst,
	}
	th := thread.create_and_start_with_poly_data(&job, proc(j: ^Job) {
		context.allocator = context.temp_allocator
		j.err = replace_file(j.src, j.dst)
	})
	time.sleep(100 * time.Millisecond)
	testing.expect(t, os.exists(dst), "the path stays while the reader has it")
	got, _ := path.read(dst, context.temp_allocator)
	testing.expect_value(t, got, "old")
	os.close(held)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, job.err, "")
	got, _ = path.read(dst, context.temp_allocator)
	testing.expect_value(t, got, "new")
}
