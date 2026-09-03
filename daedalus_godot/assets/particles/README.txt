No art ships in this folder on purpose.

Every particle effect (impact bursts, smoke trails, engine trails) uses a
small generated dot texture from scripts/placeholder_gfx.gd
(PlaceholderGfx.dot_texture), not a file. Drop a real particle texture
here and pass it to the GPUParticles2D nodes built in projectile.gd /
player.gd instead of PlaceholderGfx.dot_texture() to replace it.
