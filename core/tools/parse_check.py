import glob, sys, os
try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    print("LUA MISSING")
    sys.exit(2)

L = LuaRuntime(unpack_returned_tuples=True)
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "scripts")
bad = 0
for f in sorted(glob.glob(os.path.join(root, "*.lua"))):
    rel = os.path.relpath(f, root).replace("\\", "/")
    src = open(f, encoding="utf-8").read()
    chunk = L.eval("function(src, name) return loadstring(src, name) end")
    try:
        result = chunk(src, "@" + rel)
    except Exception as e:
        print("LOADFAIL", rel, e)
        bad += 1
        continue
    error = None
    if isinstance(result, tuple):
        result, error = result
    if result is None:
        print("SYNTAXERR", rel, error or "")
        bad += 1
    else:
        print("ok      ", rel)
print("bad =", bad)
sys.exit(1 if bad else 0)
