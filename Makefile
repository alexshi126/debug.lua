# very simple Makefile, just throws together the modules and the main
# skript.

all: debug.lua

debug.lua: debug_main.lua ui.lua loader.lua
	amalg.lua -o debug.lua -s debug_main.lua ui loader
	chmod +x debug.lua

install: debug.lua
	mkdir -p /usr/local/bin
	cp $< /usr/local/bin

clean:
	rm debug.lua
