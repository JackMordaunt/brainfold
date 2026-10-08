/*
Package shapes is the desk's contract: the questions the ui may ask of
the vault, the answers that come back, and the commands it may send. The
ui and the application both import this and never each other.

Each need is one `brain <command> --json`, and its result is that
command's object as the CLI prints it, field for field, so the desk reads
nothing the CLI does not already say. A result's error is set, and the
rest left empty, when the command could not be run or its answer read.
*/
package desk_shapes

// --- needs ------------------------------------------------------------------

// Log is `brain log`: what keeps missing, the latest lookups, and who asks.
Log :: struct {}

Log_Result :: struct {
	backlog:  []Miss, // queries that still find nothing, most missed first
	answered: []string, // queries that missed once and answer now
	recent:   []Lookup, // the latest lookups, newest first
	callers:  []Caller,
	error:    string,
}

Miss :: struct {
	query:  string,
	misses: int,
	last:   string, // "YYYY-MM-DD HH:MM:SS"
}

Lookup :: struct {
	ts:     string,
	query:  string,
	hits:   int,
	caller: string,
}

Caller :: struct {
	caller:   string,
	queries:  int,
	sessions: int,
	misses:   int,
	bytes:    int,
}

// Ledger is `brain ledger`: what lookups cost and saved.
Ledger :: struct {}

Ledger_Result :: struct {
	baseline_tokens: int, // what reading the vault whole would cost a session
	callers:         []Ledger_Caller,
	sessions:        []Ledger_Session,
	days:            []Ledger_Day,
	top_bullets:     []Top_Bullet, // the bullets served most over the same days
	error:           string,
}

Top_Bullet :: struct {
	handle:   string,
	file:     string,
	served:   int,
	sessions: int,
}

Ledger_Caller :: struct {
	caller:          string,
	sessions:        int,
	lookups:         int,
	answered:        int,
	tokens_returned: int,
	tokens_saved:    int,
}

Ledger_Session :: struct {
	session:         string,
	caller:          string,
	first, last:     string,
	lookups:         int,
	answered:        int,
	tokens_returned: int,
	tokens_saved:    int,
}

Ledger_Day :: struct {
	day:             string,
	lookups:         int,
	answered:        int,
	tokens_returned: int,
	tokens_saved:    int,
}

// Doctor is `brain doctor`: what is stale, thin, oversized, duplicated or
// orphaned, and which claims failed.
Doctor :: struct {}

Doctor_Result :: struct {
	queries_logged:    int,
	stale:             []Finding,
	thin_aliases:      []Finding,
	oversized:         []Finding,
	duplicate_handles: []Finding,
	dead_links:        []Dead_Link,
	orphan_artifacts:  []Finding,
	promote:           []Finding,
	never_returned:    []Finding,
	failed_claims:     []Failed_Claim,
	ran_at:            string, // when this report was made, HH:MM:SS local
	took_ms:           int, // how long it took
	summary:           string, // after a run the ui asked for: what changed since the report before
	error:             string,
}

// Finding is a bullet or file doctor names; which fields are set depends
// on the list it is in.
Finding :: struct {
	file:     string,
	handle:   string,
	aliases:  string,
	date:     string,
	len:      int,
	queries:  int,
	sessions: int,
}

Dead_Link :: struct {
	file:   string,
	line:   int,
	target: string,
}

Failed_Claim :: struct {
	file:    string,
	handle:  string,
	kind:    string,
	text:    string,
	why:     string,
	checked: string,
}

// Recall is `brain recall <terms> --limit n`: what past conversations said.
Recall :: struct {
	terms: string,
	limit: int,
}

Recall_Result :: struct {
	turns: []Turn,
	error: string,
}

Turn :: struct {
	id:      string,
	date:    string,
	agent:   string,
	title:   string,
	snippet: string,
}

// Around is `brain recall --around <id>`: the conversation a turn sits
// in, a few turns either side, oldest first.
Around :: struct {
	id: string,
}

Around_Result :: struct {
	id:      string, // the turn asked about, whole
	session: string,
	title:   string,
	turns:   []Around_Turn,
	error:   string,
}

Around_Turn :: struct {
	id:   string,
	ts:   string,
	role: string, // "user" or "assistant"
	body: string,
	hit:  bool, // the turn asked about
}

// Inbox is `brain inbox`: what agents proposed that a person has not
// reviewed.
Inbox :: struct {}

Inbox_Result :: struct {
	proposals: []Proposal,
	error:     string,
}

Proposal :: struct {
	n:       int, // its place in the inbox now; it moves as others go
	handle:  string,
	aliases: string,
	fact:    string,
	source:  string,
	date:    string,
	line:    string,
}

// Vault is `brain locate`, `brain version`, `brain sync status` and
// `brain review`, together: where the vault is and how it travels.
Vault :: struct {}

Vault_Result :: struct {
	vault:   string,
	tool:    string,
	version: string,
	commit:  string,
	sync:    string, // "on" or "off"
	remote:  string,
	last:    string, // the last sync, as the CLI words it
	changed: int, // changes here not yet sent
	review:  string, // "after" or "before"
	error:   string,
}

// Bullets is `brain bullet list`: every bullet, where it is and what it
// says, and the core files a new one may go to.
Bullets :: struct {}

Bullets_Result :: struct {
	bullets: []Bullet,
	files:   []string,
	error:   string,
}

Bullet :: struct {
	file:    string,
	line:    int,
	section: string,
	handle:  string,
	aliases: string,
	fact:    string,
	source:  string,
	date:    string,
}

// Bullet_Check is `brain bullet check <line>`: what lint would say of a
// bullet before it is written, asked as it is typed.
Bullet_Check :: struct {
	line: string,
}

Bullet_Check_Result :: struct {
	status:   string, // "checked", or "refused" when errors stop it being written
	errors:   []string,
	warnings: []string,
	error:    string,
}

// Install_Plan is `brain install --dry-run <path>`: what binding this
// machine to the vault at path would change, written nowhere.
Install_Plan :: struct {
	path: string,
}

Install_Plan_Result :: struct {
	ok:    bool, // the path can be a vault
	plan:  string, // what install would do, as it says it
	error: string,
}

// Outcome is a command's end, asked for under the id the command carried.
Outcome :: struct {
	id: u64,
}

Outcome_Result :: struct {
	done:    bool,
	ok:      bool,
	message: string, // what to tell the person, either way
}

// --- commands ----------------------------------------------------------------

// Command is what the ui asks of the vault. Each carries an id the ui
// chooses, and its outcome answers Outcome{id}.
Command :: union {
	Approve,
	Drop,
	Sync_Now,
	Reindex,
	Set_Review,
	Run_Doctor,
	Add_Alias,
	Remove_Alias,
	Write_Bullet,
	Replace_Bullet,
	Drop_Bullet,
	Set_Vault,
}

// Approve moves proposals into the vault, in order, each to its own file
// or to the one named. A handle finds its proposal, since a place in the
// inbox moves as others go.
Approve :: struct {
	id:      u64,
	handles: []string,
	to:      string, // "" for the file each proposal names
}

// Drop rejects proposals: they leave the inbox and are not proposed again.
Drop :: struct {
	id:      u64,
	handles: []string,
}

// Sync_Now sends what changed here and receives what other machines wrote.
Sync_Now :: struct {
	id: u64,
}

// Reindex rebuilds the index from the markdown.
Reindex :: struct {
	id: u64,
}

// Run_Doctor makes a fresh doctor report; the Doctor need is answered
// with it, and its outcome says what changed. The report is not polled:
// it takes a second or more.
Run_Doctor :: struct {
	id: u64,
}

// Add_Alias gives a bullet another name a searcher might use; the doctor
// report is made again after it.
Add_Alias :: struct {
	id:     u64,
	handle: string,
	term:   string,
}

// Remove_Alias takes a name from a bullet; the report is made again.
Remove_Alias :: struct {
	id:     u64,
	handle: string,
	term:   string,
}

// Write_Bullet adds a bullet, a whole line, to a core file: "MEMORY",
// "LEARNINGS" or "TUNINGS". It is refused if lint would refuse it or its
// handle is taken.
Write_Bullet :: struct {
	id:   u64,
	line: string,
	to:   string,
}

// Replace_Bullet puts a line in the place of the bullet named handle.
Replace_Bullet :: struct {
	id:     u64,
	handle: string,
	line:   string,
}

// Drop_Bullet takes the bullet named handle out of the vault.
Drop_Bullet :: struct {
	id:     u64,
	handle: string,
}

// Set_Vault binds this machine to the vault at path, as brain install
// does: the path recorded, the hooks and agent files pointed at it.
Set_Vault :: struct {
	id:   u64,
	path: string,
}

// Set_Review says whether a proposal answers finds before it is approved.
Set_Review :: struct {
	id:   u64,
	mode: string, // "after" or "before"
}

command_id :: proc(c: Command) -> u64 {
	switch v in c {
	case Approve:
		return v.id
	case Drop:
		return v.id
	case Sync_Now:
		return v.id
	case Reindex:
		return v.id
	case Set_Review:
		return v.id
	case Run_Doctor:
		return v.id
	case Add_Alias:
		return v.id
	case Remove_Alias:
		return v.id
	case Write_Bullet:
		return v.id
	case Replace_Bullet:
		return v.id
	case Drop_Bullet:
		return v.id
	case Set_Vault:
		return v.id
	}
	return 0
}
