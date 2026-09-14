extends RefCounted
class_name UiIcons
## Small glyphs for icon buttons, rendered from SVG at runtime so the project
## needs no imported images (the keyboard glyph lives in KeyCapture.icon()).

## A trash can: lid with a handle, tapered body, two slots.
const TRASH_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<g fill="#e6e6e6"><rect x="5" y="0.5" width="4" height="1.8" rx="0.6"/><rect x="1" y="2.6" width="12" height="1.8" rx="0.6"/>
<rect x="5" y="7.2" width="1.3" height="5.6" rx="0.4"/><rect x="7.7" y="7.2" width="1.3" height="5.6" rx="0.4"/></g>
<path d="M2.6 5.6 L3.4 14.3 Q3.5 15.2 4.4 15.2 L9.6 15.2 Q10.5 15.2 10.6 14.3 L11.4 5.6 Z" fill="none" stroke="#e6e6e6" stroke-width="1.4" stroke-linejoin="round"/>
</svg>"""

static var _trash: Texture2D


## The trash-can icon for every "delete" button.
static func trash() -> Texture2D:
	if _trash == null:
		var img := Image.new()
		if img.load_svg_from_string(TRASH_SVG, 1.0) == OK:
			_trash = ImageTexture.create_from_image(img)
	return _trash
