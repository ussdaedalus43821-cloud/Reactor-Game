No art ships in this folder on purpose.

Every hull is a procedural Polygon2D built at runtime in player.gd
(Player._hull_shape_for) / enemy.gd, colored per ship key or hostile kind.
Drop a texture here and wire it into those two functions to replace a
placeholder shape with real art -- nothing else in the project needs to
change, since collision shapes and gameplay never depend on the visual.
