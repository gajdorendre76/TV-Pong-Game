extends Node2D

const W := 1280.0
const H := 720.0
const PAD_H := 115.0
const TOTAL_ROUNDS := 3
const PAD_W := 15.0
const BALL_R := 10.0
const PADDLE_X := 48.0
const INNER_PADDLE_OFFSET := 125.0 # Csapatmódban a 3. és 4. játékos belső ütője
const MAX_BALL_SPEED := 1080.0
const MIN_HORIZONTAL_RATIO := 0.42
const PORT := 8765

var server := TCPServer.new()
var peers: Array[Dictionary] = []
var players := [360.0, 360.0, 180.0, 540.0]
var targets := [360.0, 360.0, 180.0, 540.0]
var scores := [0, 0]
var round_number: int = 1
var rounds_won: Array[int] = [0, 0]
var round_results: Array[String] = []
var round_transition: float = 0.0
var awaiting_next_round: bool = false
var round_winner: int = -1
var ball := Vector2(W / 2.0, H / 2.0)
var velocity := Vector2(380.0, 170.0)
var mode := 0 # 0 menu, 1 computer, 2 two players, 3 team 2v2
var difficulty := 1
var playing := false
var winning_score := 21
var info := ""
var host_ip := "127.0.0.1"
var connected := [false, false, false, false]
var last_input := [0.0, 0.0, 0.0, 0.0]
var elapsed := 0.0
var rng := RandomNumberGenerator.new()
var countdown: float = 0.0
var match_over: bool = false
var victory_timer: float = 0.0
var settings_background: Texture2D
var menu_background: Texture2D
var game_background: Texture2D
var menu_music: AudioStreamPlayer
var sound_player: AudioStreamPlayer
var sounds: Dictionary = {}
var qr_texture: Texture2D
var qr_ready: bool = false
var previous_paddles := [360.0, 360.0, 180.0, 540.0]
var paddle_velocities := [0.0, 0.0, 0.0, 0.0]
var ball_trail: Array[Vector2] = []
var ai_target: float = H / 2.0
var ai_timer: float = 0.0
var serve_direction: float = 1.0
var rally_hits: int = 0
var paddle_glows: Array[float] = [0.0, 0.0, 0.0, 0.0]
var score_flash: float = 0.0
var flash_side: int = 0
var sparks: Array[Dictionary] = []
var connection_timeout: float = 6.0
# A labda, az ütők és a visszaszámlálás kapcsolatvesztéskor megállnak.
var connection_paused: bool = false
var waiting_for_connection: bool = false
var resume_countdown: float = 0.0
var ever_connected: Array[bool] = [false, false, false, false]
var rally_speed_gain: float = 1.035
var spin_strength: float = 0.29
var show_trail: bool = true
var screen: int = 0 # 0 = főmenü, 1 = beállítások, 2 = játék
var sound_enabled: bool = true
var volume_percent: int = 70
var win_by_two: bool = false
var fullscreen_enabled: bool = true
var menu_buttons: Array[Dictionary] = []
var setting_buttons: Array[Dictionary] = []
var hover_button: int = -1
var game_speed: float = 1.0
var settings_path: String = "user://pong_settings.cfg"
var player_names: Array[String] = ["PLAYER 1", "PLAYER 2", "PLAYER 3", "PLAYER 4"]
var name_editor: LineEdit
var editing_player: int = -1

# Helyi, ismétlődő háttérzene játék közben, fix 20%-os hangerőn.
var intro_player: VideoStreamPlayer
var intro_active: bool = false
var gameplay_music: AudioStreamPlayer

func _ready() -> void:
	rng.randomize()
	_load_settings()
	host_ip = _find_ip()
	var err := server.listen(PORT, "0.0.0.0")
	info = "Szerver: " + ("OK" if err == OK else "HIBA: " + str(err))
	_setup_audio()
	_setup_menu_media()
	_setup_name_editor()
	_prepare_qr()
	if fullscreen_enabled:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	set_process(true)

func _find_ip() -> String:
	for ip in IP.get_local_addresses():
		if ip.begins_with("192.168.") or ip.begins_with("10.") or ip.begins_with("172."):
			if not ip.begins_with("172.17."):
				return ip
	return "127.0.0.1"

func _process(delta: float) -> void:
	if intro_active:
		return
	elapsed += delta
	if match_over and screen == 2:
		victory_timer -= delta
		if victory_timer <= 0.0:
			_back_to_menu()
	_serve_http()
	_update_menu_music()
	_update_gameplay_music()
	_update_connection_guard(delta)
	if not connection_paused and not awaiting_next_round and countdown > 0.0:
		var previous: int = ceili(countdown)
		countdown = maxf(0.0, countdown - delta)
		if ceili(countdown) != previous:
			_play_sound("count" if countdown > 0.0 else "start")
	for i in range(4):
		paddle_glows[i] = maxf(0.0, paddle_glows[i] - delta * 3.4)
	score_flash = maxf(0.0, score_flash - delta * 1.7)
	for j in range(sparks.size() - 1, -1, -1):
		var particle: Dictionary = sparks[j]
		particle["life"] = float(particle["life"]) - delta
		if float(particle["life"]) <= 0.0:
			sparks.remove_at(j)
		else:
			particle["pos"] = (particle["pos"] as Vector2) + (particle["vel"] as Vector2) * delta
			sparks[j] = particle
	# A mozgás sebessége és a labda visszapattanása az ütő tényleges
	# elmozdulását is figyelembe veszi.
	for i in range(4):
		previous_paddles[i] = players[i]
	if mode == 1 and not connection_paused:
		_update_ai(delta)
	for i in range(4 if mode == 3 else (2 if mode == 2 else 1)):
		if connection_paused:
			break
		players[i] = move_toward(players[i], clampf(targets[i], _current_paddle_height() / 2.0, H - _current_paddle_height() / 2.0), 1100.0 * delta)
	for i in range(4):
		paddle_velocities[i] = (players[i] - previous_paddles[i]) / maxf(delta, 0.0001)
	if playing and not connection_paused and not awaiting_next_round and countdown <= 0.0:
		# Rövid részlépések: gyors labdánál sem lép át az ütőn.
		var steps: int = maxi(1, ceili(velocity.length() * delta / 5.0))
		steps = mini(steps, 48)
		for step in range(steps):
			_advance_ball(delta / float(steps))
			if not playing or countdown > 0.0:
				break
		if show_trail:
			ball_trail.push_front(ball)
			if ball_trail.size() > 8:
				ball_trail.pop_back()
	queue_redraw()


func _update_connection_guard(delta: float) -> void:
	for i in range(4):
		connected[i] = elapsed - last_input[i] < connection_timeout and last_input[i] > 0.0
	if (not playing and round_transition <= 0.0) or match_over or screen != 2:
		connection_paused = false
		waiting_for_connection = false
		resume_countdown = 0.0
		return
	var required: int = 4 if mode == 3 else (2 if mode == 2 else 1)
	var all_online: bool = true
	for i in range(required):
		if not connected[i]:
			all_online = false
	if not all_online:
		connection_paused = true
		waiting_for_connection = true
		resume_countdown = 0.0
	elif waiting_for_connection:
		# A teljes mérkőzés továbbra is áll, amíg a visszaszámlálás le nem jár.
		resume_countdown = 3.0
		waiting_for_connection = false
	elif connection_paused:
		resume_countdown = maxf(0.0, resume_countdown - delta)
		if resume_countdown <= 0.0:
			connection_paused = false
			ball_trail.clear()

func _update_ai(delta: float) -> void:
	var speeds: Array[float] = [255.0, 420.0, 670.0]
	var round_ai_boost: float = 1.0 + 0.08 * float(round_number - 1)
	var reaction: Array[float] = [0.40, 0.20, 0.085]
	var error: Array[float] = [72.0, 34.0, 9.0]
	ai_timer -= delta
	if ai_timer <= 0.0:
		ai_timer = reaction[difficulty]
		var projected: float = H / 2.0
		if velocity.x > 0.0 and playing and countdown <= 0.0:
			var travel: float = (W - PADDLE_X - ball.x) / maxf(velocity.x, 1.0)
			var raw_y: float = ball.y + velocity.y * maxf(travel, 0.0)
			var span: float = H - 2.0 * BALL_R
			var folded: float = fposmod(raw_y - BALL_R, span * 2.0)
			projected = BALL_R + (folded if folded <= span else span * 2.0 - folded)
			ai_target = clampf(projected + rng.randf_range(-error[difficulty], error[difficulty]), _current_paddle_height() / 2.0, H - _current_paddle_height() / 2.0)
	players[1] = move_toward(players[1], ai_target, speeds[difficulty] * round_ai_boost * delta)

func _advance_ball(dt: float) -> void:
	ball += velocity * dt
	if ball.y <= BALL_R and velocity.y < 0.0:
		ball.y = BALL_R
		velocity.y = -velocity.y
		_spawn_sparks(ball, Color(0.35, 0.85, 1.0), 5)
		_play_sound("bounce")
	elif ball.y >= H - BALL_R and velocity.y > 0.0:
		ball.y = H - BALL_R
		velocity.y = -velocity.y
		_spawn_sparks(ball, Color(0.35, 0.85, 1.0), 5)
		_play_sound("bounce")
	for i in range(4 if mode == 3 else 2):
		var side: int = i % 2
		var px: float = _paddle_center_x(i)
		var incoming: bool = velocity.x < 0.0 if side == 0 else velocity.x > 0.0
		if not incoming:
			continue
		if absf(ball.x - px) <= PAD_W / 2.0 + BALL_R and absf(ball.y - players[i]) <= _team_paddle_height() / 2.0 + BALL_R:
			var hit: float = clampf((ball.y - players[i]) / (_team_paddle_height() / 2.0), -1.0, 1.0)
			var speed: float = minf(velocity.length() * rally_speed_gain + 5.0, MAX_BALL_SPEED * (1.0 + 0.15 * float(round_number - 1)))
			var angle: float = clampf(hit * (0.90 + 0.08 * float(round_number - 1)) + (paddle_velocities[i] / 1100.0) * spin_strength, -1.08, 1.08)
			var outgoing: float = 1.0 if side == 0 else -1.0
			velocity = Vector2(outgoing * maxf(cos(angle), MIN_HORIZONTAL_RATIO) * speed, sin(angle) * speed)
			ball.x = px + outgoing * (PAD_W / 2.0 + BALL_R + 0.5)
			rally_hits += 1
			paddle_glows[i] = 1.0
			_spawn_sparks(ball, Color(1.0, 0.66, 0.22), 10)
			_play_sound("bounce")
			break
	if ball.x < -BALL_R:
		_point(1)
	elif ball.x > W + BALL_R:
		_point(0)

func _paddle_center_x(index: int) -> float:
	var inset: float = INNER_PADDLE_OFFSET if mode == 3 and index >= 2 else 0.0
	return PADDLE_X + inset if index % 2 == 0 else W - PADDLE_X - inset

func _current_paddle_height() -> float:
	return PAD_H * (1.0 - 0.10 * float(round_number - 1))

func _team_paddle_height() -> float:
	return _current_paddle_height() * (0.65 if mode == 3 else 1.0)

func _player_label(index: int) -> String:
	return "COMPUTER" if mode == 1 and index == 1 else (("TEAM A" if index == 0 else "TEAM B") if mode == 3 else player_names[index])

func _point(winner: int) -> void:
	scores[winner] += 1
	score_flash = 0.75
	flash_side = winner
	_spawn_sparks(Vector2(W * (0.25 if winner == 0 else 0.75), 115.0), Color(1.0, 0.6, 0.2), 22)
	_play_sound("score")
	if scores[winner] >= winning_score:
		_finish_round(winner)
	else:
		countdown = 3.0
		_reset_ball(-1.0 if winner == 0 else 1.0)

func _finish_round(winner: int) -> void:
	playing = false
	round_winner = winner
	rounds_won[winner] += 1
	round_results.append("Round %d: %s (%d:%d)" % [round_number, _player_label(winner), scores[0], scores[1]])
	_play_sound("win")
	if rounds_won[winner] >= 2 or round_number >= TOTAL_ROUNDS:
		match_over = true
		victory_timer = 6.0
		awaiting_next_round = false
		info = _player_label(winner) + " IS THE CHAMPION!"
	else:
		awaiting_next_round = true
		info = _player_label(winner) + " WINS THE ROUND!"

func _begin_next_round() -> void:
	if not awaiting_next_round or match_over or connection_paused:
		return
	awaiting_next_round = false
	round_number += 1
	scores = [0, 0]
	playing = true
	round_winner = -1
	countdown = 3.0
	players = [180.0, 180.0, 540.0, 540.0] if mode == 3 else [360.0, 360.0, 180.0, 540.0]
	targets = players.duplicate()
	previous_paddles = players.duplicate()
	ai_target = H / 2.0
	ai_timer = 0.0
	ball_trail.clear()
	_reset_ball(-1.0 if rng.randi_range(0, 1) == 0 else 1.0)
	_play_sound("count")

func _reset_ball(direction: float) -> void:
	ball = Vector2(W / 2.0, H / 2.0)
	velocity = Vector2(direction * 400.0, rng.randf_range(-145.0, 145.0)) * game_speed * (1.0 + 0.20 * float(round_number - 1))
	ball_trail.clear()
	rally_hits = 0

func _start(which: int) -> void:
	mode = which
	round_number = 1
	rounds_won = [0, 0]
	round_results.clear()
	round_transition = 0.0
	awaiting_next_round = false
	round_winner = -1
	screen = 2
	playing = true
	match_over = false
	victory_timer = 0.0
	connection_paused = false
	waiting_for_connection = false
	resume_countdown = 0.0
	countdown = 3.0
	_play_sound("count")
	scores = [0, 0]
	players = [180.0, 180.0, 540.0, 540.0] if mode == 3 else [360.0, 360.0, 180.0, 540.0]
	targets = players.duplicate()
	previous_paddles = players.duplicate()
	ai_target = H / 2.0
	ai_timer = 0.0
	info = ""
	sparks.clear()
	score_flash = 0.0
	_reset_ball(-1.0 if rng.randi_range(0, 1) == 0 else 1.0)

func _input(event: InputEvent) -> void:
	if intro_active:
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode in [KEY_ESCAPE, KEY_ENTER, KEY_SPACE]:
				_end_intro()
		elif event is InputEventMouseButton and event.pressed:
			_end_intro()
		return
	if editing_player >= 0:
		return
	if event is InputEventMouseMotion and screen != 2:
		hover_button = _button_at(event.position)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if screen == 2 and awaiting_next_round:
			_begin_next_round()
		elif screen != 2:
			_activate_button(_button_at(event.position))
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F11:
			_toggle_fullscreen()
		elif screen == 0:
			match event.keycode:
				KEY_1: _start(1)
				KEY_2: _start(2)
				KEY_3: _start(3)
				KEY_4, KEY_O: screen = 1
				KEY_ESCAPE: get_tree().quit()
		elif screen == 1:
			match event.keycode:
				KEY_ESCAPE, KEY_BACKSPACE: _back_to_menu()
				KEY_1: difficulty = (difficulty + 1) % 3; _save_settings()
				KEY_2: pass
				KEY_3: volume_percent = (volume_percent + 10) % 110; _apply_volume(); _save_settings()
				KEY_4: sound_enabled = not sound_enabled; _save_settings()
				KEY_5: game_speed = 1.0 if game_speed > 1.15 else game_speed + 0.15; _save_settings()
				KEY_6: _toggle_fullscreen()
		else:
			match event.keycode:
				KEY_ENTER, KEY_SPACE:
					if awaiting_next_round:
						_begin_next_round()
					elif match_over and mode > 0:
						_back_to_menu()
				KEY_T: show_trail = not show_trail; _save_settings()
				KEY_ESCAPE: _back_to_menu()
				KEY_W:
					if not connection_paused:
						targets[0] -= 45.0
				KEY_S:
					if not connection_paused:
						targets[0] += 45.0
				KEY_UP:
					if not connection_paused:
						targets[1] -= 45.0
				KEY_DOWN:
					if not connection_paused:
						targets[1] += 45.0
	for i in range(4):
		targets[i] = clampf(targets[i], _current_paddle_height() / 2.0, H - _current_paddle_height() / 2.0)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(W, H)), Color.BLACK)
	if screen == 1 and settings_background != null:
		draw_texture_rect(settings_background, Rect2(0, 0, W, H), false)
	elif screen == 0 and menu_background != null:
		# A feltöltött 16:9-es CRT Pong kép kitölti a főmenü hátterét.
		draw_texture_rect(menu_background, Rect2(0, 0, W, H), false)
	elif screen == 2 and game_background != null:
		# Játék közben a feltöltött CRT-háttér látható; a középvonal már a képen szerepel.
		draw_texture_rect(game_background, Rect2(0, 0, W, H), false)
	else:
		for y in range(0, 720, 32):
			draw_rect(Rect2(637, y, 6, 17), Color(0.35, 0.35, 0.35))
	var font := ThemeDB.fallback_font
	if screen == 0:
		_draw_menu(font)
	elif screen == 1:
		_draw_settings(font)
	else:
		if score_flash > 0.0:
			var flash_x: float = 0.0 if flash_side == 0 else W * 0.5
			draw_rect(Rect2(flash_x, 0.0, W * 0.5, H), Color(0.18, 0.55, 1.0, score_flash * 0.10))
		for i in range(4 if mode == 3 else 2):
			var px: float = _paddle_center_x(i) - PAD_W * 0.5
			var glow: float = paddle_glows[i]
			if glow > 0.0:
				draw_rect(Rect2(px - 9.0, players[i] - _team_paddle_height() * 0.5 - 9.0, PAD_W + 18.0, _team_paddle_height() + 18.0), Color(0.24, 0.78, 1.0, glow * 0.19))
			draw_rect(Rect2(px - 4.0, players[i] - _team_paddle_height() * 0.5 - 4.0, PAD_W + 8.0, _team_paddle_height() + 8.0), Color(0.55, 0.87, 1.0, glow * 0.35))
			draw_rect(Rect2(px, players[i] - _team_paddle_height() * 0.5, PAD_W, _team_paddle_height()), Color.WHITE)
		for particle in sparks:
			var tint: Color = particle["color"]
			tint.a = clampf(float(particle["life"]) / float(particle["max_life"]), 0.0, 1.0)
			draw_circle(particle["pos"], float(particle["radius"]), tint)
		if show_trail and playing:
			for j in range(ball_trail.size() - 1, -1, -1):
				var alpha: float = 0.08 + 0.23 * (1.0 - float(j) / maxf(float(ball_trail.size()), 1.0))
				draw_circle(ball_trail[j], BALL_R * (0.5 + 0.45 * (1.0 - float(j) / 8.0)), Color(1.0, 1.0, 1.0, alpha))
		draw_circle(ball, BALL_R, Color.WHITE)
		_label(font, Vector2(475, 100), str(scores[0]), 64)
		_label(font, Vector2(750, 100), str(scores[1]), 64)
		_draw_player_name(font, (player_names[0] + " + " + player_names[2]) if mode == 3 else player_names[0], connected[0] and connected[2] if mode == 3 else connected[0], 320.0)
		_draw_player_name(font, (player_names[1] + " + " + player_names[3]) if mode == 3 else ("COMPUTER" if mode == 1 else player_names[1]), (connected[1] and connected[3]) if mode == 3 else (true if mode == 1 else connected[1]), 960.0)
		_centered_label(font, 128.0, "ROUND %d/%d   |   ROUNDS WON: %d - %d" % [round_number, TOTAL_ROUNDS, rounds_won[0], rounds_won[1]], 22)
		if awaiting_next_round:
			draw_rect(Rect2(160.0, 245.0, 960.0, 230.0), Color(0.0, 0.0, 0.0, 0.88))
			_centered_label(font, 315.0, info, 29)
			_centered_label(font, 367.0, "NEXT: ROUND %d" % (round_number + 1), 27)
			_centered_label(font, 420.0, "ENTER / SPACE / CLICK TO START", 22)
		elif connection_paused:
			draw_rect(Rect2(240.0, 265.0, 800.0, 190.0), Color(0.0, 0.0, 0.0, 0.88))
			var pause_text: String = "CONNECTION LOST" if waiting_for_connection else "RESUMING IN: " + str(ceili(resume_countdown))
			_centered_label(font, 345.0, pause_text, 34)
			_centered_label(font, 400.0, "WAITING FOR PHONE" if waiting_for_connection else "GET READY!", 22)
		elif playing and countdown > 0.0:
			var message := str(ceili(countdown))
			_label(font, Vector2(604, 355), message, 76)
		if match_over:
			draw_rect(Rect2(130, 205, 1020, 320), Color(0.0, 0.0, 0.0, 0.92))
			_centered_label(font, 260.0, info, 34)
			_centered_label(font, 305.0, "ROUNDS WON: %d - %d" % [rounds_won[0], rounds_won[1]], 27)
			for result_i in range(round_results.size()):
				_centered_label(font, 345.0 + result_i * 34.0, round_results[result_i], 20)
			_centered_label(font, 480.0, "RETURNING TO MAIN MENU...", 22)

func _draw_player_name(font: Font, name: String, online: bool, center_x: float) -> void:
	var display_name: String = name + ("  ●" if online else "  ○")
	var size: int = 22
	var text_width: float = font.get_string_size(display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(font, Vector2(center_x - text_width * 0.5, 44.0), display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.77, 1.0, 0.81) if online else Color(1.0, 0.72, 0.58))

func _spawn_sparks(origin: Vector2, tint: Color, amount: int) -> void:
	for i in range(amount):
		var angle: float = rng.randf_range(0.0, TAU)
		var speed: float = rng.randf_range(55.0, 200.0)
		var lifetime: float = rng.randf_range(0.18, 0.55)
		sparks.append({"pos": origin, "vel": Vector2.from_angle(angle) * speed, "life": lifetime, "max_life": lifetime, "radius": rng.randf_range(1.5, 3.4), "color": tint})
	if sparks.size() > 130:
		sparks = sparks.slice(sparks.size() - 130)

func _label(font: Font, pos: Vector2, value: String, size: int) -> void:
	draw_string(font, pos, value, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color.WHITE)

func _serve_http() -> void:
	while server.is_connection_available():
		var peer := server.take_connection()
		if peer != null:
			peers.append({"socket": peer, "buffer": "", "age": 0.0})
	for i in range(peers.size() - 1, -1, -1):
		var p: Dictionary = peers[i]
		var sock: StreamPeerTCP = p["socket"]
		sock.poll()
		if sock.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			peers.remove_at(i)
			continue
		var available := sock.get_available_bytes()
		if available > 0:
			var chunk := sock.get_utf8_string(mini(available, 16384))
			p["buffer"] += chunk
		if p["buffer"].length() > 20000:
			peers.remove_at(i)
			continue
		var request: String = p["buffer"]
		var header_end := request.find("\r\n\r\n")
		if header_end < 0:
			continue
		var head := request.substr(0, header_end)
		var length := 0
		for line in head.split("\r\n"):
			if line.to_lower().begins_with("content-length:"):
				length = int(line.split(":", false, 1)[1].strip_edges())
		if request.length() - header_end - 4 < length:
			continue
		var first_line := head.split("\r\n")[0]
		var path := first_line.split(" ")[1] if first_line.split(" ").size() > 1 else "/"
		var body := request.substr(header_end + 4, length)
		var response := "OK"
		var mime := "text/plain; charset=utf-8"
		if path.begins_with("/move"):
			var json = JSON.parse_string(body)
			if json is Dictionary:
				var who := int(json.get("player", 0)) - 1
				if who >= 0 and who <= 3:
					targets[who] = clampf(float(json.get("y", 0.5)) * H, _current_paddle_height() / 2.0, H - _current_paddle_height() / 2.0)
					last_input[who] = elapsed
					connected[who] = true
					ever_connected[who] = true
		elif path.begins_with("/join"):
			var json = JSON.parse_string(body)
			var who: int = 0
			if json is Dictionary:
				who = int(json.get("player", 0)) - 1
			if who >= 0 and who <= 3:
				last_input[who] = elapsed
				connected[who] = true
				ever_connected[who] = true
			response = JSON.stringify({"ok": who >= 0 and who <= 3, "connected": connected, "names": player_names})
			mime = "application/json; charset=utf-8"
		elif path.begins_with("/name"):
			var json = JSON.parse_string(body)
			if json is Dictionary:
				var who: int = int(json.get("player", 0)) - 1
				var new_name: String = str(json.get("name", "")).strip_edges()
				new_name = new_name.replace("\n", " ").replace("\r", " ").replace("\t", " ")
				if who >= 0 and who <= 1 and not new_name.is_empty():
					player_names[who] = new_name.substr(0, 22)
					last_input[who] = elapsed
					connected[who] = true
					ever_connected[who] = true
					_save_settings()
					queue_redraw()
			response = JSON.stringify({"names": player_names})
			mime = "application/json; charset=utf-8"
		elif path.begins_with("/status"):
			response = JSON.stringify({"mode": mode, "playing": playing, "scores": scores, "names": player_names, "connected": connected, "countdown": countdown, "match_over": match_over, "connection_paused": connection_paused, "waiting_for_connection": waiting_for_connection, "resume_countdown": resume_countdown, "server_ok": true, "round": round_number, "rounds_won": rounds_won, "round_transition": round_transition, "required": 4 if mode == 3 else (2 if mode == 2 else 1)})
			mime = "application/json"
		else:
			response = _controller_html()
			mime = "text/html; charset=utf-8"
		var bytes := response.to_utf8_buffer()
		var header := "HTTP/1.1 200 OK\r\nContent-Type: " + mime + "\r\nContent-Length: " + str(bytes.size()) + "\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
		sock.put_data(header.to_utf8_buffer())
		sock.put_data(bytes)
		sock.disconnect_from_host()
		peers.remove_at(i)

func _controller_html() -> String:
	return FileAccess.get_file_as_string("res://controller.html")

# A QR-kódot a helyi qrencode segédprogram készíti. Nincs internetfüggőség.
func _prepare_qr() -> void:
	if host_ip == "127.0.0.1":
		return
	var output: Array = []
	var path := OS.get_user_data_dir().path_join("pong_qr.png")
	var code: int = OS.execute("qrencode", ["-o", path, "-s", "8", "-m", "2", "http://" + host_ip + ":" + str(PORT)], output, true)
	if code == 0 and FileAccess.file_exists(path):
		var picture := Image.new()
		if picture.load(path) == OK:
			qr_texture = ImageTexture.create_from_image(picture)
			qr_ready = true

func _setup_intro() -> void:
	intro_player = VideoStreamPlayer.new()
	intro_player.name = "IntroVideo"
	intro_player.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	intro_player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	intro_player.expand = true
	intro_player.stream = load("res://intro.ogv") as VideoStream
	add_child(intro_player)
	intro_player.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	intro_player.finished.connect(_end_intro)
	if intro_player.stream != null:
		intro_player.play()
	else:
		_end_intro()

func _end_intro() -> void:
	if not intro_active:
		return
	intro_active = false
	intro_player.stop()
	intro_player.hide()
	_update_menu_music()
	queue_redraw()

func _setup_menu_media() -> void:
	menu_background = load("res://menu_background.png") as Texture2D
	settings_background = load("res://settings_background.png") as Texture2D
	game_background = load("res://game_background.png") as Texture2D
	menu_music = AudioStreamPlayer.new()
	menu_music.name = "MenuMusic"
	add_child(menu_music)
	var track: AudioStreamMP3 = load("res://menu_music.mp3") as AudioStreamMP3
	if track != null:
		track.loop = true
		menu_music.stream = track
	gameplay_music = AudioStreamPlayer.new()
	gameplay_music.name = "GameplayMusic"
	add_child(gameplay_music)
	var game_track: AudioStreamMP3 = load("res://game_music.mp3") as AudioStreamMP3
	if game_track != null:
		game_track.loop = true
		gameplay_music.stream = game_track
	gameplay_music.volume_db = linear_to_db(0.20)
	_update_menu_music()

func _update_menu_music() -> void:
	if menu_music == null:
		return
	var should_play: bool = not intro_active and screen != 2 and sound_enabled and volume_percent > 0
	menu_music.volume_db = linear_to_db(maxf(float(volume_percent) / 100.0 * 0.65, 0.001))
	if should_play and not menu_music.playing and menu_music.stream != null:
		menu_music.play()
	elif not should_play and menu_music.playing:
		menu_music.stop()

func _update_gameplay_music() -> void:
	if gameplay_music == null:
		return
	var should_play: bool = screen == 2
	gameplay_music.volume_db = linear_to_db(0.20)
	if should_play and not gameplay_music.playing and gameplay_music.stream != null:
		gameplay_music.play()
	elif not should_play and gameplay_music.playing:
		gameplay_music.stop()

func _setup_audio() -> void:
	sound_player = AudioStreamPlayer.new()
	add_child(sound_player)
	_apply_volume()
	for name in ["bounce", "score", "count", "start", "win"]:
		var stream := AudioStreamWAV.new()
		stream.format = AudioStreamWAV.FORMAT_16_BITS
		stream.mix_rate = 22050
		stream.stereo = false
		var hz: float = {"bounce": 440.0, "score": 220.0, "count": 330.0, "start": 660.0, "win": 880.0}[name]
		var duration: float = {"bounce": 0.06, "score": 0.18, "count": 0.12, "start": 0.24, "win": 0.5}[name]
		var samples := PackedByteArray()
		for i in range(int(22050.0 * duration)):
			var t: float = float(i) / 22050.0
			var envelope: float = 1.0 - t / duration
			var wave: float = (1.0 if sin(TAU * hz * t) >= 0.0 else -1.0) * envelope * 0.18
			var sample: int = int(wave * 32767.0)
			samples.append(sample & 255)
			samples.append((sample >> 8) & 255)
		stream.data = samples
		sounds[name] = stream

func _play_sound(name: String) -> void:
	if sound_enabled and sounds.has(name) and sound_player != null:
		sound_player.stream = sounds[name]
		sound_player.play()


func _cycle_score() -> void:
	winning_score = 21

func _apply_volume() -> void:
	if sound_player != null:
		sound_player.volume_db = linear_to_db(maxf(float(volume_percent) / 100.0, 0.001))

func _toggle_fullscreen() -> void:
	fullscreen_enabled = not fullscreen_enabled
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen_enabled else DisplayServer.WINDOW_MODE_WINDOWED)
	_save_settings()

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("players", "name1", player_names[0])
	cfg.set_value("players", "name2", player_names[1])
	cfg.set_value("players", "name3", player_names[2])
	cfg.set_value("players", "name4", player_names[3])
	cfg.set_value("game", "difficulty", difficulty)
	cfg.set_value("game", "winning_score", winning_score)
	cfg.set_value("game", "win_by_two", win_by_two)
	cfg.set_value("game", "speed", game_speed)
	cfg.set_value("display", "fullscreen", fullscreen_enabled)
	cfg.set_value("display", "trail", show_trail)
	cfg.set_value("audio", "enabled", sound_enabled)
	cfg.set_value("audio", "volume", volume_percent)
	cfg.save(settings_path)

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(settings_path) != OK:
		return
	player_names[0] = str(cfg.get_value("players", "name1", "PLAYER 1"))
	player_names[1] = str(cfg.get_value("players", "name2", "PLAYER 2"))
	player_names[2] = str(cfg.get_value("players", "name3", "PLAYER 3"))
	player_names[3] = str(cfg.get_value("players", "name4", "PLAYER 4"))
	difficulty = clampi(int(cfg.get_value("game", "difficulty", 1)), 0, 2)
	winning_score = int(cfg.get_value("game", "winning_score", 21))
	winning_score = 21
	win_by_two = bool(cfg.get_value("game", "win_by_two", false))
	game_speed = clampf(float(cfg.get_value("game", "speed", 1.0)), 1.0, 1.3)
	fullscreen_enabled = bool(cfg.get_value("display", "fullscreen", true))
	show_trail = bool(cfg.get_value("display", "trail", true))
	sound_enabled = bool(cfg.get_value("audio", "enabled", true))
	volume_percent = clampi(int(cfg.get_value("audio", "volume", 70)), 0, 100)

func _back_to_menu() -> void:
	screen = 0
	mode = 0
	playing = false
	match_over = false
	round_transition = 0.0
	connection_paused = false
	waiting_for_connection = false
	resume_countdown = 0.0
	countdown = 0.0

func _button_at(pos: Vector2) -> int:
	var buttons: Array[Dictionary] = menu_buttons if screen == 0 else setting_buttons
	for i in range(buttons.size()):
		if (buttons[i]["rect"] as Rect2).has_point(pos):
			return i
	return -1

func _activate_button(index: int) -> void:
	if index < 0: return
	if screen == 0:
		match index:
			0: _start(1)
			1: _start(2)
			2: _start(3)
			3: screen = 1
			4: get_tree().quit()
	elif screen == 1:
		match index:
			0: difficulty = (difficulty + 1) % 3
			1: pass
			2: volume_percent = (volume_percent + 10) % 110; _apply_volume()
			3: sound_enabled = not sound_enabled
			4: game_speed = 1.0 if game_speed > 1.15 else game_speed + 0.15
			5: _toggle_fullscreen()
			6: _back_to_menu()
		_save_settings()

func _draw_button(font: Font, rect: Rect2, label: String, selected: bool, size: int = 27) -> void:
	draw_rect(rect, Color(0.17, 0.20, 0.24) if selected else Color(0.08, 0.09, 0.11), true)
	draw_rect(rect, Color(0.75, 0.89, 1.0) if selected else Color(0.30, 0.34, 0.38), false, 2.0)
	var text_size: Vector2 = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	_label(font, Vector2(rect.position.x + (rect.size.x - text_size.x) / 2.0, rect.position.y + (rect.size.y + text_size.y) / 2.0 - 5.0), label, size)

# Középre igazítás a tényleges betűszélesség alapján.
func _centered_label(font: Font, y: float, value: String, size: int) -> void:
	var text_width: float = font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	_label(font, Vector2((W - text_width) * 0.5, y), value, size)

func _draw_menu(font: Font) -> void:
	menu_buttons.clear()
	# A feltöltött háttér tartalmazza a címet és a négy díszített gombot.
	# A gombfeliratokat közvetlenül ezekre rajzoljuk, külön téglalapok nélkül.
	var names: Array[String] = ["1  •  VS COMPUTER", "2  •  TWO PLAYERS", "3  •  TEAM MATCH 2V2", "4  •  SETTINGS", "EXIT"]
	for i in range(names.size()):
		var rect := Rect2(390.0, 207.0 + float(i) * 66.0, 500.0, 55.0)
		menu_buttons.append({"rect": rect})
		var label_size: int = 24
		# A Kilépés felirat is átlátszó, nincs külön gombháttér.
		var text_size: Vector2 = font.get_string_size(names[i], HORIZONTAL_ALIGNMENT_LEFT, -1, label_size)
		var baseline: float = rect.position.y + (rect.size.y + text_size.y) * 0.5 - 5.0
		var pos := Vector2((W - text_size.x) * 0.5, baseline)
		if hover_button == i:
			draw_string(font, pos + Vector2(0, 2), names[i], HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, Color(1.0, 0.40, 0.08))
		else:
			draw_string(font, pos, names[i], HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, Color.WHITE)
	# A QR-kód és a csatlakozási cím a díszített gombok alá kerül.
	_centered_label(font, 558.0, "PHONE: http://" + host_ip + ":" + str(PORT), 23)
	if qr_ready and qr_texture != null:
		var qr_size: float = 92.0
		draw_texture_rect(qr_texture, Rect2((W - qr_size) * 0.5, 570.0, qr_size, qr_size), false)
	else:
		_centered_label(font, 612.0, "QR: sudo pacman -S qrencode", 18)
	_centered_label(font, 687.0, "Same Wi-Fi • F11: fullscreen", 19)

func _draw_settings(font: Font) -> void:
	setting_buttons.clear()
	_centered_label(font, 105.0, "SETTINGS", 52)
	var names: Array[String] = [
		"1  Difficulty: " + ["EASY", "MEDIUM", "HARD"][difficulty],
		"2  Round length: 21 points",
		"3  Volume: " + str(volume_percent) + "%",
		"4  Sound effects: " + ("ON" if sound_enabled else "OFF"),
		"5  Ball speed: " + str(int(round(game_speed * 100.0))) + "%",
		"6  Fullscreen: " + ("ON" if fullscreen_enabled else "OFF"),
		"BACK TO MAIN MENU"
	]
	for i in range(names.size()):
		var rect := Rect2(295.0, 155.0 + float(i) * 67.0, 690.0, 55.0)
		setting_buttons.append({"rect": rect})
		# A díszített gombok a háttérkép részei: csak átlátszó kattintási terület és felirat.
		var label_size: int = 24
		var text_size: Vector2 = font.get_string_size(names[i], HORIZONTAL_ALIGNMENT_LEFT, -1, label_size)
		var baseline: float = rect.position.y + (rect.size.y + text_size.y) * 0.5 - 5.0
		var pos := Vector2((W - text_size.x) * 0.5, baseline)
		var color := Color(1.0, 0.72, 0.32) if hover_button == i else Color.WHITE
		draw_string(font, pos, names[i], HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, color)
	_centered_label(font, 685.0, "Click or press 1–6 • ESC: back", 19)

func _setup_name_editor() -> void:
	name_editor = LineEdit.new()
	name_editor.position = Vector2(385, 328)
	name_editor.size = Vector2(510, 58)
	name_editor.max_length = 22
	name_editor.placeholder_text = "Player name"
	name_editor.visible = false
	name_editor.add_theme_font_size_override("font_size", 30)
	add_child(name_editor)
	name_editor.text_submitted.connect(_name_submitted)

func _edit_name(player_index: int) -> void:
	editing_player = player_index
	name_editor.text = player_names[player_index]
	name_editor.visible = true
	name_editor.grab_focus()
	name_editor.select_all()

func _name_submitted(_value: String) -> void:
	var new_name: String = name_editor.text.strip_edges()
	if not new_name.is_empty():
		player_names[editing_player] = new_name
	name_editor.visible = false
	name_editor.release_focus()
	editing_player = -1
	_save_settings()
	queue_redraw()
