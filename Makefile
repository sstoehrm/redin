.PHONY: build run clean fennel test

ODIN := odin
BUILD_DIR := build
FNL_SRC := $(shell find src/runtime src/app -name '*.fnl' 2>/dev/null)
FNL_OUT := $(patsubst %.fnl,$(BUILD_DIR)/%.lua,$(FNL_SRC))

# Build the Odin host binary
build: $(BUILD_DIR)/redin

$(BUILD_DIR)/redin: $(wildcard src/host/*.odin)
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build src/host -out:$(BUILD_DIR)/redin

# Run the host binary (dev mode)
run: build
	./$(BUILD_DIR)/redin

# Compile Fennel -> Lua
fennel: $(FNL_OUT)

$(BUILD_DIR)/%.lua: %.fnl
	@mkdir -p $(dir $@)
	lua -e 'local f=require("vendor.fennel.fennel"); local h=io.open("$<"); local s=h:read("*a"); h:close(); local out,_=f.compileString(s,{filename="$<"}); print(out)' > $@

# Run tests
test:
	$(ODIN) test src/host

clean:
	rm -rf $(BUILD_DIR)
