class_name PlaceholderGfx
extends RefCounted

## No art assets ship with this project (see assets/README inside each
## folder) -- every ship, projectile and particle is a procedural vector
## shape or a generated dot texture instead. This is the one place that
## generates the dot: GPUParticles2D needs *some* texture to render a
## visible point rather than depending on an unspecified engine default,
## so trails and impact bursts all pull from here.
##
## Built once per unique (size, color) pair and cached, since a shot fired
## every 0.073s has no business re-rasterising an image that often.

static var _cache: Dictionary = {}


static func dot_texture(size: int = 10, color: Color = Color.WHITE) -> ImageTexture:
	var key := "%d:%s" % [size, color.to_html(true)]
	if _cache.has(key):
		return _cache[key]

	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size, size) * 0.5
	var radius := size * 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(center)
			var falloff := clampf(1.0 - d / radius, 0.0, 1.0)
			image.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * falloff))

	var tex := ImageTexture.create_from_image(image)
	_cache[key] = tex
	return tex
