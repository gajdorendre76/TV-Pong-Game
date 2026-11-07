extends Control

@onready var video: VideoStreamPlayer = $Video
var leaving: bool = false

func _ready() -> void:
    # Az intro külön indító jelenetben fut: a főmenü még nem létezik.
    video.finished.connect(_finish_intro)
    get_window().mode = Window.MODE_FULLSCREEN
    await get_tree().process_frame
    if not leaving:
        video.play()

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo:
        if event.keycode in [KEY_ESCAPE, KEY_ENTER, KEY_SPACE]:
            _finish_intro()
    elif event is InputEventMouseButton and event.pressed:
        _finish_intro()

func _finish_intro() -> void:
    if leaving:
        return
    leaving = true
    video.stop()
    get_tree().change_scene_to_file("res://main.tscn")
