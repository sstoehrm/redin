-- Minimal test runner for Fennel test files
-- Usage: luajit test/lua/runner.lua test/lua/test_*.fnl

package.path = "vendor/fennel/?.lua;" .. package.path
package.loaded["fennel"] = {}
pcall(dofile, "vendor/fennel/fennel.lua")
package.loaded["fennel"] = nil
local fennel = require("fennel")
table.insert(package.loaders or package.searchers, fennel.searcher)

fennel.path = "src/runtime/?.fnl;" .. fennel.path

local passed, failed = 0, 0
local failures = {}

if #arg == 0 then
    print("Usage: luajit test/lua/runner.lua <test_file.fnl> [...]")
    os.exit(1)
end

for i = 1, #arg do
    local file = arg[i]
    print("Running: " .. file)
    local ok, result = pcall(fennel.dofile, file)
    if not ok then
        failed = failed + 1
        table.insert(failures, {name = file, err = result})
        print("  ERROR: " .. tostring(result))
    elseif type(result) ~= "table" then
        print("  WARN: file did not return a test table")
    else
        for name, fn in pairs(result) do
            if type(fn) == "function" then
                local tok, terr = pcall(fn)
                if tok then
                    passed = passed + 1
                    print("  PASS: " .. name)
                else
                    failed = failed + 1
                    table.insert(failures, {name = file .. "::" .. name, err = terr})
                    print("  FAIL: " .. name)
                    print("    " .. tostring(terr))
                end
            end
        end
    end
end

print(string.format("\n%d passed, %d failed", passed, failed))
if #failures > 0 then
    print("\nFailures:")
    for _, f in ipairs(failures) do
        print("  " .. f.name .. ": " .. tostring(f.err))
    end
end
os.exit(failed > 0 and 1 or 0)
