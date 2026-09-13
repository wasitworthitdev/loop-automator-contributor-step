// Punches fully transparent holes into whatever the CanvasItem draws.
//
// The overlay and the pick window sit on top of the desktop, and the screen
// reads used by Pixel Detect / colour sampling (CopyFromScreen) see them too.
// Anything drawn on a sampled pixel — a guide's fill, a grid line, the playback
// tracker, the pick reticle — would tint the read. So every Pixel Detect rect
// (the overlay scans the whole rect) and every sample point (the pick window's
// cursor) is listed here and left transparent, so reads hit the desktop
// underneath.
shader_type canvas_item;

const int MAX_HOLES = 128;
uniform int hole_count = 0;
uniform vec2 holes[MAX_HOLES];   // in the CanvasItem's canvas (= window pixel) space
uniform float hole_radius = 3.0;
uniform int rect_count = 0;
uniform vec4 rects[MAX_HOLES];   // x, y, w, h in the same space; covers pixels [x, x+w) × [y, y+h)

varying vec2 canvas_pos;

void vertex() {
	canvas_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	for (int i = 0; i < hole_count; i++) {
		if (distance(canvas_pos, holes[i]) <= hole_radius) {
			COLOR.a = 0.0;
		}
	}
	for (int i = 0; i < rect_count; i++) {
		vec4 r = rects[i];
		if (canvas_pos.x >= r.x && canvas_pos.x < r.x + r.z && canvas_pos.y >= r.y && canvas_pos.y < r.y + r.w) {
			COLOR.a = 0.0;
		}
	}
}
