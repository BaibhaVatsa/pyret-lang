provide *
import runtime-lib as R
import builtin-modules as B
import make-standalone as MS
import load-lib as L
import either as E
import json as JSON
import ast as A
import pathlib as P
import sha as crypto
import string-dict as SD
import render-error-display as RED
import file as F
import filelib as FS
import error as ERR
import system as SYS
import file("js-ast.arr") as J
import file("concat-lists.arr") as C
import file("compile-lib.arr") as CL
import file("compile-structs.arr") as CS
import file("locators/file.arr") as FL
import file("locators/builtin.arr") as BL
import file("locators/jsfile.arr") as JSF
import file("js-of-pyret.arr") as JSP

j-fun = J.j-fun
j-var = J.j-var
j-id = J.j-id
j-method = J.j-method
j-block = J.j-block
j-true = J.j-true
j-false = J.j-false
j-num = J.j-num
j-str = J.j-str
j-return = J.j-return
j-assign = J.j-assign
j-if = J.j-if
j-if1 = J.j-if1
j-new = J.j-new
j-app = J.j-app
j-list = J.j-list
j-obj = J.j-obj
j-dot = J.j-dot
j-bracket = J.j-bracket
j-field = J.j-field
j-dot-assign = J.j-dot-assign
j-bracket-assign = J.j-bracket-assign
j-try-catch = J.j-try-catch
j-throw = J.j-throw
j-expr = J.j-expr
j-binop = J.j-binop
j-and = J.j-and
j-lt = J.j-lt
j-eq = J.j-eq
j-neq = J.j-neq
j-geq = J.j-geq
j-unop = J.j-unop
j-decr = J.j-decr
j-incr = J.j-incr
j-not = J.j-not
j-instanceof = J.j-instanceof
j-ternary = J.j-ternary
j-null = J.j-null
j-parens = J.j-parens
j-switch = J.j-switch
j-case = J.j-case
j-default = J.j-default
j-label = J.j-label
j-break = J.j-break
j-while = J.j-while
j-for = J.j-for

clist = C.clist

type Loadable = CS.Loadable


type Either = E.Either

fun uri-to-path(uri, name):
  name + "-" + crypto.sha256(uri)
end

fun get-cached-if-available(basedir, loc) block:
  get-cached-if-available-known-mtimes(basedir, loc, [SD.string-dict:])
end
fun get-cached-if-available-known-mtimes(basedir, loc, max-dep-times) block:
  saved-path = P.join(basedir, uri-to-path(loc.uri(), loc.name()))
  #print("Looking for builtin module " + loc.uri() + " at: " + saved-path + "\n")
  dependency-based-mtime =
    if max-dep-times.has-key(loc.uri()): max-dep-times.get-value(loc.uri())
    else: loc.get-modified-time()
    end
  if not(F.file-exists(saved-path + "-static.js")) or
     (F.file-times(saved-path + "-static.js").mtime < dependency-based-mtime) block:
    #print("It wasn't there\n")
    cases(Option) loc.get-uncached():
      | some(shadow loc) => loc
      | none => loc
    end
  else:
    uri = loc.uri()
    static-path = saved-path + "-static"
    raw = B.builtin-raw-locator(static-path)
    {
      method get-uncached(self): some(loc) end,
      method needs-compile(_, _): false end,
      method get-modified-time(self):
        F.file-times(static-path + ".js").mtime
      end,
      method get-options(self, options):
        options.{ check-mode: false }
      end,
      method get-module(_):
        raise("Should never fetch source for builtin module " + static-path)
      end,
      method get-extra-imports(self):
        CS.standard-imports
      end,
      method get-dependencies(_):
        deps = raw.get-raw-dependencies()
        raw-array-to-list(deps).map(CS.make-dep)
      end,
      method get-native-modules(_):
        natives = raw.get-raw-native-modules()
        raw-array-to-list(natives).map(CS.requirejs)
      end,
      method get-globals(_):
        CS.standard-globals
      end,

      method uri(_): uri end,
      method name(_): loc.name() end,

      method set-compiled(_, _, _): nothing end,
      method get-compiled(self):
        provs = CS.provides-from-raw-provides(self.uri(), {
            uri: self.uri(),
            modules: raw-array-to-list(raw.get-raw-module-provides()),
            values: raw-array-to-list(raw.get-raw-value-provides()),
            aliases: raw-array-to-list(raw.get-raw-alias-provides()),
            datatypes: raw-array-to-list(raw.get-raw-datatype-provides())
          })
        some(CS.module-as-string(provs, CS.no-builtins, CS.computed-none,
            CS.ok(JSP.ccp-file(F.real-path(saved-path + "-module.js")))))
      end,

      method _equals(self, other, req-eq):
        req-eq(self.uri(), other.uri())
      end
    }
  end
end

fun get-file-locator(basedir, real-path):
  loc = FL.file-locator(real-path, CS.standard-globals)
  get-cached-if-available(basedir, loc)
end

fun get-builtin-locator(basedir, modname):
  loc = BL.make-builtin-locator(modname)
  get-cached-if-available(basedir, loc)
end

fun get-builtin-test-locator(basedir, modname):
  loc = BL.make-builtin-locator(modname).{
    method uri(_): "builtin-test://" + modname end
  }
  get-cached-if-available(basedir, loc)
end

fun get-loadable(basedir, l, max-dep-times) -> Option<Loadable>:
  locuri = l.locator.uri()
  saved-path = P.join(basedir, uri-to-path(locuri, l.locator.name()))
  if not(F.file-exists(saved-path + "-static.js")) or
     (F.file-times(saved-path + "-static.js").mtime < max-dep-times.get-value(locuri)):
    none
  else:
    raw-static = B.builtin-raw-locator(saved-path + "-static")
    provs = CS.provides-from-raw-provides(locuri, {
      uri: locuri,
      modules: raw-array-to-list(raw-static.get-raw-module-provides()),
      values: raw-array-to-list(raw-static.get-raw-value-provides()),
      aliases: raw-array-to-list(raw-static.get-raw-alias-provides()),
      datatypes: raw-array-to-list(raw-static.get-raw-datatype-provides())
    })
    some(CS.module-as-string(provs, CS.no-builtins, CS.computed-none, CS.ok(JSP.ccp-file(saved-path + "-module.js"))))
  end
end

fun set-loadable(basedir, locator, loadable) -> String block:
  doc: "Returns the module path of the cached file"
  when not(FS.exists(basedir)):
    FS.create-dir(basedir)
  end
  locuri = loadable.provides.from-uri
  cases(CS.CompileResult) loadable.result-printer block:
    | ok(ccp) =>
      cases(JSP.CompiledCodePrinter) ccp block:
        | ccp-dict(dict) =>
          save-static-path = P.join(basedir, uri-to-path(locuri, locator.name()) + "-static.js")
          save-module-path = P.join(basedir, uri-to-path(locuri, locator.name()) + "-module.js")
          fs = F.output-file(save-static-path, false)
          fm = F.output-file(save-module-path, false)
          ccp.print-js-static(fs.display)
          ccp.print-js-runnable(fm.display)
          fs.flush()
          fs.close-file()
          fm.flush()
          fm.close-file()
          save-module-path
        | else =>
          save-path = P.join(basedir, uri-to-path(locuri, locator.name()) + ".js")
          f = F.output-file(save-path, false)
          ccp.print-js-runnable(f.display)
          f.flush()
          f.close-file()
          save-path
      end
    | err(_) => ""
  end
end

fun get-cli-module-storage(storage-dir :: String):
  {
    method load-modules(self, to-compile, max-dep-times) block:
      maybe-modules = for map(t from to-compile):
        get-loadable(storage-dir, t, max-dep-times)
      end
      modules = [SD.mutable-string-dict:]
      for each2(m from maybe-modules, t from to-compile):
        cases(Option<Loadable>) m:
          | none => nothing
          | some(shadow m) =>
            # NOTE(joe):
            # With re-providing, this is unsafe, because modules can alias values in others
            # Therefore, we need to wait to add modules until after all their dependencies
            # have been processed, otherwise the type-checker will not be able
            # to compute the type environment
            #
            modules.set-now(t.locator.uri(), m)
        end
      end
      modules
    end
  }
end

type CLIContext = {
  current-load-path :: String,
  cache-base-dir :: String
}

fun get-real-path(current-load-path :: String, dep :: CS.Dependency):
  this-path = dep.arguments.get(0)
  if P.is-absolute(this-path):
    P.relative(current-load-path, this-path)
  else:
    P.join(current-load-path, this-path)
  end
end

fun module-finder(ctxt :: CLIContext, dep :: CS.Dependency):
  cases(CS.Dependency) dep:
    | dependency(protocol, args) =>
      if protocol == "file":
        clp = ctxt.current-load-path
        real-path = get-real-path(clp, dep)
        new-context = ctxt.{current-load-path: P.dirname(real-path)}
        if F.file-exists(real-path):
          CL.located(get-file-locator(ctxt.cache-base-dir, real-path), new-context)
        else:
          raise("Cannot find import " + torepr(dep))
        end
      else if protocol == "builtin-test":
        l = get-builtin-test-locator(ctxt.cache-base-dir, args.first)
        force-check-mode = l.{
          method get-options(self, options):
            options.{ check-mode: true, type-check: false }
          end
        }
        CL.located(force-check-mode, ctxt)
      else if protocol == "file-no-cache":
        clp = ctxt.current-load-path
        real-path = get-real-path(clp, dep)
        new-context = ctxt.{current-load-path: P.dirname(real-path)}
        if F.file-exists(real-path):
          CL.located(FL.file-locator(real-path, CS.standard-globals), new-context)
        else:
          raise("Cannot find import " + torepr(dep))
        end
      else if protocol == "js-file":
        clp = ctxt.current-load-path
        real-path = get-real-path(clp, dep)
        new-context = ctxt.{current-load-path: P.dirname(real-path)}
        locator = JSF.make-jsfile-locator(real-path)
        CL.located(locator, new-context)
      else:
        raise("Unknown import type: " + protocol)
      end
    | builtin(modname) =>
      CL.located(get-builtin-locator(ctxt.cache-base-dir, modname), ctxt)
  end
end

default-start-context = {
  current-load-path: P.resolve("./"),
  cache-base-dir: P.resolve("./compiled")
}

default-test-context = {
  current-load-path: P.resolve("./"),
  cache-base-dir: P.resolve("./tests/compiled")
}

fun compile(path, options):
  base-module = CS.dependency("file", [list: path])
  base = module-finder({
    current-load-path: P.resolve("./"),
    cache-base-dir: options.compiled-cache
  }, base-module)
  wl = CL.compile-worklist(module-finder, base.locator, base.context)
  compiled = CL.compile-program(wl, options)
  compiled
end

fun handle-compilation-errors(problems, options) block:
  for lists.each(e from problems) block:
    options.log-error(RED.display-to-string(e.render-reason(), torepr, empty))
    options.log-error("\n")
  end
  raise("There were compilation errors")
end

fun propagate-exit(result) block:
  when L.is-exit(result):
    code = L.get-exit-code(result)
    SYS.exit(code)
  end
  when L.is-exit-quiet(result):
    code = L.get-exit-code(result)
    SYS.exit-quiet(code)
  end
end

fun run(path, options, subsequent-command-line-arguments):
  stats = SD.make-mutable-string-dict()
  maybe-program = build-program(path, options, stats)
  cases(Either) maybe-program block:
    | left(problems) =>
      handle-compilation-errors(problems, options)
    | right(program) =>
      command-line-arguments = link(path, subsequent-command-line-arguments)
      result = L.run-program(R.make-runtime(), L.empty-realm(), program.js-ast.to-ugly-source(), options, command-line-arguments)
      if L.is-success-result(result):
        L.render-check-results(result)
      else:
        _ = propagate-exit(result)
        L.render-error-message(result)
      end
  end
end

fun build-program(path, options, stats) block:
  doc: ```Returns the program as a JavaScript AST of module list and dependency map,
          and its native dependencies as a list of strings```

  print-progress-clearing = lam(s, to-clear):
    when options.display-progress:
      options.log(s, to-clear)
    end
  end
  print-progress = lam(s): print-progress-clearing(s, none) end
  var str = "Gathering dependencies..."
  fun clear-and-print(new-str) block:
    print-progress-clearing(new-str, some(string-length(str)))
    str := new-str
  end
  print-progress(str)
  base-module = CS.dependency("file", [list: path])
  base = module-finder({
    current-load-path: P.resolve("./"),
    cache-base-dir: options.compiled-cache
  }, base-module)
  clear-and-print("Compiling worklist...")
  wl = CL.compile-worklist(module-finder, base.locator, base.context)

  max-dep-times = for fold(sd from [SD.string-dict:], located from wl):
    cur-mod-time = located.locator.get-modified-time()
    dm = located.dependency-map
    max-dep-time = for SD.fold-keys-now(mdt from cur-mod-time, dep-key from dm):
      dep-loc = dm.get-value-now(dep-key)
      num-max(sd.get-value(dep-loc.uri()), mdt)
    end
    sd.set(located.locator.uri(), max-dep-time)
  end

  shadow wl = for map(located from wl):
    located.{ locator: get-cached-if-available-known-mtimes(options.compiled-cache, located.locator, max-dep-times) }
  end

  clear-and-print("Loading existing compiled modules...")
  storage = get-cli-module-storage(options.compiled-cache)
  starter-modules = storage.load-modules(wl, max-dep-times)


  total-modules = wl.length()
  cached-modules = starter-modules.count-now()
  var num-compiled = cached-modules
  shadow options = options.{
    method should-profile(_, locator):
      options.add-profiling and (locator.uri() == base.locator.uri())
    end,
    method before-compile(_, locator) block:
      num-compiled := num-compiled + 1
      clear-and-print("Compiling " + num-to-string(num-compiled) + "/" + num-to-string(total-modules)
          + ": " + locator.name())
    end,
    method on-compile(_, locator, loadable, trace) block:
      locator.set-compiled(loadable, SD.make-mutable-string-dict()) # TODO(joe): What are these supposed to be?
      clear-and-print(num-to-string(num-compiled) + "/" + num-to-string(total-modules)
          + " modules compiled " + "(" + locator.name() + ")")
      when options.collect-times:
        comp = for map(stage from trace):
          stage.name + ": " + tostring(stage.time) + "ms"
        end
        stats.set-now(locator.name(), comp)
      end
      when num-compiled == total-modules:
        print-progress("\nCleaning up and generating standalone...\n")
      end
      module-path = set-loadable(options.compiled-cache, locator, loadable)
      if (num-compiled == total-modules) and options.collect-all:
        # Don't squash the final JS-AST if we're collecting all of them, so
        # it can be pretty-printed after all
        loadable
      else:
        cases(CS.Loadable) loadable:
          | module-as-string(prov, env, post-env, rp) =>
            CS.module-as-string(prov, env, post-env, CS.ok(JSP.ccp-file(module-path)))
          | else => loadable
        end
      end
    end
  }
  CL.compile-standalone(wl, starter-modules, options)
end

fun build-runnable-standalone(path, require-config-path, outfile, options) block:
  stats = SD.make-mutable-string-dict()
  config = JSON.read-json(F.file-to-string(require-config-path)).dict.unfreeze()
  cases(Option) config.get-now("typable-builtins"):
    | none => nothing
    | some(tb) =>
      cases(JSON.JSON) tb:
        | j-arr(l) => 
          BL.set-typable-builtins(l.map(_.s))
        | else => raise("Expected a list for typable-builtins, but got: " + to-repr(tb))
      end
  end
  maybe-program = build-program(path, options, stats)
  cases(Either) maybe-program block:
    | left(problems) =>
      handle-compilation-errors(problems, options)
    | right(program) =>
      config.set-now("out", JSON.j-str(outfile))
      when not(config.has-key-now("baseUrl")):
        config.set-now("baseUrl", JSON.j-str(options.compiled-cache))
      end

      when options.collect-times: stats.set-now("standalone", time-now()) end
      make-standalone-res = MS.make-standalone(program.natives, program.js-ast,
        JSON.j-obj(config.freeze()).serialize(), options.standalone-file,
        options.deps-file, options.this-pyret-dir)

      html-res = if is-some(options.html-file):
        MS.make-html-file(outfile, options.html-file.value)
      else:
        true
      end

      ans = make-standalone-res and html-res

      when options.collect-times block:
        standalone-end = time-now() - stats.get-value-now("standalone")
        stats.set-now("standalone", [list: "Outputing JS: " + tostring(standalone-end) + "ms"])
        for SD.each-key-now(key from stats):
          print(key + ": \n" + stats.get-value-now(key).join-str(", \n") + "\n")
        end
      end
      ans
  end
end

fun build-require-standalone(path, options):
  stats = SD.make-mutable-string-dict()
  program = build-program(path, options, stats)

  natives = j-list(true, for C.map_list(n from program.natives): n end)

  define-name = j-id(A.s-name(A.dummy-loc, "define"))

  prog = j-block([clist:
      j-app(define-name, [clist: natives, j-fun(J.next-j-fun-id(), [clist:],
        j-block([clist:
          j-return(program.js-ast)
        ]))
      ])
    ])

  print(prog.to-ugly-source())
end
