std = "lua54"
max_line_length = 110
self = false -- wibox widget methods (fit/draw) must take self
-- AwesomeWM globals used by the desktop module.
read_globals = { "awesome", "screen", "root" }
files["spec/"] = { std = "+busted" }
exclude_files = { "node_modules/", ".claude/" }
