class_name ReactorBridge
extends Node

## Godot <-> NovaLang/Python bridge.
##
## One interface, three interchangeable backends. The panel calls tick()
## and gets a state Dictionary; it never learns or cares which of these
## produced it:
##
##   PIPE    a persistent `python3 -u sim/reactor_server.py` child process,
##           spoken to over its stdin/stdout with one line of JSON each
##           way. This is the real thing: RK4 in NumPy, policy in NovaLang.
##           Desktop only -- macOS, Windows, Linux.
##
##   TCP     the same daemon, already running in a terminal, reached at
##           127.0.0.1:8642 (`python3 reactor_server.py --tcp 8642`).
##           Handy while tuning: you can watch its stderr and hot-reload
##           the rules without restarting Godot.
##
##   LOCAL   sim_local.gd -- the RK4 core ported to GDScript, running the
##           *same* reactor_rules.nova through nova_vm.gd. No process, no
##           socket, no dependencies.
##
## iOS and Web have no process API at all, so they always use LOCAL. On
## desktop the bridge tries PIPE, then TCP, then falls back to LOCAL, and
## it falls back mid-run too if the daemon dies. A reactor that goes blank
## because a helper process crashed is a worse outcome than one that
## quietly finishes the shift in-engine.
##
## Override the choice with a command-line argument:
##     godot -- --backend=local     (also: pipe, tcp, auto)

signal backend_selected(kind: int, label: String, info: Dictionary)
signal backend_lost(reason: String)

enum Backend { NONE, PIPE, TCP, LOCAL }

const SIM_DIR_RES := "res://sim"
## Explicit list: an exported .pck exposes these through FileAccess, but
## DirAccess cannot enumerate non-resource files, so they must be named.
const SIM_FILES := [
	"reactor_server.py",
	"reactor_physics.py",
	"nova_runtime.py",
	"reactor_rules.nova",
]

const TCP_HOST := "127.0.0.1"
const TCP_PORT := 8642
const TCP_CONNECT_TIMEOUT_MS := 400
const TCP_REQUEST_TIMEOUT_MS := 1000

const PYTHON_CANDIDATES_UNIX := [
	"python3",
	"/opt/homebrew/bin/python3",   # Apple silicon Homebrew
	"/usr/local/bin/python3",      # Intel Homebrew
	"/usr/bin/python3",            # Apple's own, and most Linux distros
	"/usr/bin/env",                # last resort: env python3
]
const PYTHON_CANDIDATES_WINDOWS := ["python.exe", "py.exe", "python"]

var backend := Backend.NONE
var backend_label := "not started"
var last_error := ""
var server_info: Dictionary = {}

var _local: LocalSim = null
var _pid := -1
var _stdio: FileAccess = null
var _stderr: FileAccess = null
var _tcp: StreamPeerTCP = null
var _tcp_buffer := ""
var _python_path := ""
var _forced := ""


func _ready() -> void:
	_forced = _read_backend_override()


func _exit_tree() -> void:
	shutdown()


# ==========================================================================
# Lifecycle
# ==========================================================================

## Bring a backend up. Safe to call again to re-negotiate after a failure.
func start() -> void:
	shutdown()
	last_error = ""
	if _forced == "":
		_forced = _read_backend_override()

	if _forced == "local":
		_use_local("forced by --backend=local")
		return

	if _process_api_available():
		if _forced == "auto" or _forced == "pipe":
			if _try_pipe():
				return
		if _forced == "auto" or _forced == "tcp":
			if _try_tcp():
				return
	elif _forced == "pipe" or _forced == "tcp":
		last_error = "%s cannot spawn or reach an external process" % OS.get_name()

	_use_local(last_error if last_error != "" else "no external sim reachable")


func shutdown() -> void:
	if _stdio != null and _stdio.is_open():
		# Ask politely first; the daemon exits its read loop on `quit`.
		_stdio.store_line(JSON.stringify({"cmd": "quit"}))
		_stdio.flush()
		_stdio.close()
	_stdio = null
	if _stderr != null:
		_stderr.close()
	_stderr = null
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	if _tcp != null:
		_tcp.disconnect_from_host()
	_tcp = null
	_tcp_buffer = ""
	backend = Backend.NONE


## iOS and Web have no process API; Godot before 4.3 has no pipe API.
func _process_api_available() -> bool:
	match OS.get_name():
		"macOS", "Windows", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			return true
	return false


func _read_backend_override() -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with("--backend="):
			var value := arg.split("=")[1].strip_edges().to_lower()
			if ["auto", "pipe", "tcp", "local"].has(value):
				return value
	return "auto"


# ==========================================================================
# Backend: LOCAL (GDScript RK4 + NovaLang VM)
# ==========================================================================

func _use_local(reason: String) -> void:
	_local = LocalSim.new()
	backend = Backend.LOCAL
	if _local.ready:
		backend_label = "GODOT / NovaLang VM"
	else:
		backend_label = "GODOT (policy error)"
		last_error = _local.error
	server_info = _local.hello()
	server_info["reason"] = reason
	backend_selected.emit(backend, backend_label, server_info)


# ==========================================================================
# Backend: PIPE (persistent python3 child process)
# ==========================================================================

func _try_pipe() -> bool:
	if not OS.has_method("execute_with_pipe"):
		last_error = "this Godot build has no OS.execute_with_pipe (needs 4.3+)"
		return false

	var script_path := _prepare_sim_files()
	if script_path == "":
		return false

	_python_path = _find_python()
	if _python_path == "":
		last_error = "no working python3 found on PATH or in the usual places"
		return false

	var args := PackedStringArray()
	if _python_path.ends_with("env"):
		args.append("python3")
	args.append("-u")            # unbuffered: never let a reply sit in a buffer
	args.append(script_path)

	var pipe: Dictionary = OS.execute_with_pipe(_python_path, args)
	if pipe.is_empty() or not pipe.has("stdio"):
		last_error = "could not launch %s" % _python_path
		return false

	_stdio = pipe["stdio"]
	_stderr = pipe.get("stderr", null)
	_pid = int(pipe.get("pid", -1))

	var hello := _request_pipe({"cmd": "hello"})
	if hello.is_empty() or not hello.get("ok", false):
		last_error = "python daemon did not answer the handshake"
		shutdown()
		return false

	backend = Backend.PIPE
	server_info = hello
	backend_label = "PYTHON / %s" % str(hello.get("backend", "?")).to_upper()
	backend_selected.emit(backend, backend_label, server_info)
	return true


## Copy the Python + NovaLang sources somewhere the OS can actually execute
## them. In the editor res:// is already a real directory, so we run in
## place and edits to the .nova file take effect on the next reset. In an
## exported build they live inside the .pck, so they are unpacked into
## user:// first.
func _prepare_sim_files() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path(SIM_DIR_RES + "/reactor_server.py")

	var dest_dir := "user://sim"
	var err := DirAccess.make_dir_recursive_absolute(dest_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		last_error = "could not create %s (error %d)" % [dest_dir, err]
		return ""

	for name in SIM_FILES:
		var src := "%s/%s" % [SIM_DIR_RES, name]
		if not FileAccess.file_exists(src):
			last_error = "%s is missing from the export (check include_filter)" % src
			return ""
		var data := FileAccess.get_file_as_bytes(src)
		var out := FileAccess.open("%s/%s" % [dest_dir, name], FileAccess.WRITE)
		if out == null:
			last_error = "could not write %s/%s" % [dest_dir, name]
			return ""
		out.store_buffer(data)
		out.close()

	return ProjectSettings.globalize_path(dest_dir + "/reactor_server.py")


func _find_python() -> String:
	var candidates: Array = PYTHON_CANDIDATES_WINDOWS if OS.get_name() == "Windows" \
		else PYTHON_CANDIDATES_UNIX
	for candidate in candidates:
		var probe := PackedStringArray()
		if String(candidate).ends_with("env"):
			probe.append("python3")
		probe.append("--version")
		var output: Array = []
		if OS.execute(candidate, probe, output, true) == 0:
			return candidate
	return ""


func _request_pipe(payload: Dictionary) -> Dictionary:
	if _stdio == null or not _stdio.is_open():
		_fail_over("the python daemon's pipe closed")
		return {}
	if _pid > 0 and not OS.is_process_running(_pid):
		_fail_over("the python daemon exited")
		return {}

	_stdio.store_line(JSON.stringify(payload))
	_stdio.flush()

	var line := _stdio.get_line()
	if line.is_empty() and _stdio.eof_reached():
		_fail_over("the python daemon stopped responding")
		return {}

	var parsed = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "unparseable reply from the daemon: %s" % line.left(120)
		return {}
	return parsed


# ==========================================================================
# Backend: TCP (daemon already running in a terminal)
# ==========================================================================

func _try_tcp() -> bool:
	_tcp = StreamPeerTCP.new()
	if _tcp.connect_to_host(TCP_HOST, TCP_PORT) != OK:
		last_error = "nothing listening on %s:%d" % [TCP_HOST, TCP_PORT]
		_tcp = null
		return false

	var deadline := Time.get_ticks_msec() + TCP_CONNECT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		_tcp.poll()
		if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
		if _tcp.get_status() == StreamPeerTCP.STATUS_ERROR:
			break
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		last_error = "could not connect to %s:%d" % [TCP_HOST, TCP_PORT]
		_tcp = null
		return false

	_tcp.set_no_delay(true)
	var hello := _request_tcp({"cmd": "hello"})
	if hello.is_empty() or not hello.get("ok", false):
		last_error = "the tcp daemon did not answer the handshake"
		_tcp = null
		return false

	backend = Backend.TCP
	server_info = hello
	backend_label = "PYTHON-TCP / %s" % str(hello.get("backend", "?")).to_upper()
	backend_selected.emit(backend, backend_label, server_info)
	return true


func _request_tcp(payload: Dictionary) -> Dictionary:
	if _tcp == null:
		_fail_over("the tcp connection is gone")
		return {}
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_fail_over("the tcp daemon disconnected")
		return {}

	var body := JSON.stringify(payload) + "\n"
	if _tcp.put_data(body.to_utf8_buffer()) != OK:
		_fail_over("could not write to the tcp daemon")
		return {}

	var deadline := Time.get_ticks_msec() + TCP_REQUEST_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		_tcp.poll()
		var available := _tcp.get_available_bytes()
		if available > 0:
			var chunk: Array = _tcp.get_data(available)
			if chunk.size() == 2 and int(chunk[0]) == OK:
				var bytes: PackedByteArray = chunk[1]
				_tcp_buffer += bytes.get_string_from_utf8()
		var newline := _tcp_buffer.find("\n")
		if newline >= 0:
			var line := _tcp_buffer.substr(0, newline)
			_tcp_buffer = _tcp_buffer.substr(newline + 1)
			var parsed = JSON.parse_string(line)
			if typeof(parsed) != TYPE_DICTIONARY:
				last_error = "unparseable tcp reply: %s" % line.left(120)
				return {}
			return parsed
		if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_fail_over("the tcp daemon disconnected mid-request")
			return {}

	_fail_over("the tcp daemon timed out")
	return {}


# ==========================================================================
# Failure handling
# ==========================================================================

## Any backend that stops answering hands the reactor to the in-engine sim
## rather than freezing the panel. The run continues from a cold core --
## the external process owned the state, and it is gone.
func _fail_over(reason: String) -> void:
	if backend == Backend.LOCAL:
		return
	push_warning("[ReactorBridge] %s -- falling back to the in-engine sim" % reason)
	last_error = reason
	shutdown()
	backend_lost.emit(reason)
	_use_local(reason)


# ==========================================================================
# Public API -- identical replies whichever backend answers
# ==========================================================================

func is_ready() -> bool:
	return backend != Backend.NONE


func reset(seed_value: int = 0) -> Dictionary:
	match backend:
		Backend.PIPE:
			return _request_pipe({"cmd": "reset", "seed": seed_value})
		Backend.TCP:
			return _request_tcp({"cmd": "reset", "seed": seed_value})
		Backend.LOCAL:
			return _local.reset(seed_value)
	return {}


## Advance the plant by `steps` fixed 0.05 s ticks and return the new state.
func tick(steps: int, rod_target_a: float, rod_target_b: float,
		scram_pressed: bool, faults_enabled: bool = true) -> Dictionary:
	if steps <= 0:
		return {}
	var payload := {
		"cmd": "tick",
		"steps": steps,
		"rod_target_a": rod_target_a,
		"rod_target_b": rod_target_b,
		"scram": scram_pressed,
		"faults": faults_enabled,
	}
	match backend:
		Backend.PIPE:
			return _request_pipe(payload)
		Backend.TCP:
			return _request_tcp(payload)
		Backend.LOCAL:
			return _local.advance(steps, rod_target_a, rod_target_b,
					scram_pressed, faults_enabled)
	return {}


## Re-read reactor_rules.nova without restarting. Only the Python backends
## support this in place; the in-engine sim rebuilds its VM instead.
func reload_rules() -> Dictionary:
	match backend:
		Backend.PIPE:
			return _request_pipe({"cmd": "reload"})
		Backend.TCP:
			return _request_tcp({"cmd": "reload"})
		Backend.LOCAL:
			_local = LocalSim.new()
			return _local.snapshot()
	return {}


func fixed_dt() -> float:
	return float(server_info.get("dt", ReactorCore.PHYSICS_DT))
