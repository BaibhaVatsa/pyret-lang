#lang pyret

provide *
provide-types *
import srcloc as SL
import ast as A
import parse-pyret as PP
import file("compile-structs.arr") as CS
import file("ast-anf.arr") as N
import file("type-structs.arr") as T
import file("type-check-structs.arr") as TCS
import string-dict as SD
import either as E
import lists as L

type URI = String
type Loc = SL.Srcloc

type NameOrigin = T.NameOrigin
local = T.local
module-uri = T.module-uri
dependency = T.dependency

fun ok-last(stmt):
  not(
    A.is-s-let(stmt) or
    A.is-s-var(stmt) or
    A.is-s-rec(stmt) or
    A.is-s-fun(stmt) or
    A.is-s-data(stmt) or
    A.is-s-contract(stmt) or
    A.is-s-check(stmt) or
    A.is-s-type(stmt) or
    A.is-s-newtype(stmt)
  )
end

fun checkers(l): A.s-app(l, A.s-dot(l, A.s-id(l, A.s-name(l, "builtins")), "current-checker"), [list: ]) end

fun append-nothing-if-necessary(prog :: A.Program) -> A.Program:
  cases(A.Program) prog:
    | s-program(l1, _provide, _provide-types, provides, imports, body) =>
      cases(A.Expr) body:
        | s-block(l2, stmts) =>
          cases(List) stmts:
            | empty =>
              A.s-program(l1, _provide, _provide-types, provides, imports,
                A.s-block(l2, [list: A.s-id(l2, A.s-name(l2, "nothing"))]))
            | link(_, _) =>
              last-stmt = stmts.last()
              if ok-last(last-stmt): prog
              else:
                A.s-program(l1, _provide, _provide-types, provides, imports,
                  A.s-block(l2, stmts + [list: A.s-id(A.dummy-loc, A.s-name(l2, "nothing"))]))
              end
          end
        | else => prog
      end
  end
end

fun wrap-if-needed(exp :: A.Expr) -> A.Expr:
  l = exp.l
  if ok-last(exp) and not(A.is-s-spy-block(exp)):
    A.s-app(l, A.s-dot(l, A.s-id(l, A.s-name(l, "builtins")), "trace-value"),
      [list: A.s-srcloc(l, l), exp])
  else: exp
  end
end

fun wrap-toplevels(prog :: A.Program) -> A.Program:
  cases(A.Program) prog:
    | s-program(l1, _prov, _prov-types, provides, imps, body) =>
      new-body = cases(A.Expr) body:
        | s-block(l2, stmts) => A.s-block(l2, map(wrap-if-needed, stmts))
        | else => wrap-if-needed(body)
      end
      A.s-program(l1, _prov, _prov-types, provides, imps, new-body)
  end
end

fun count-apps(expr) block:
  var count = 0
  visitor = A.default-iter-visitor.{
      method s-app(self, l, f, args) block:
        count := count + 1
        f.visit(self) and args.map(_.visit(self))
      end
    }
  expr.visit(visitor)
  count
end

data BindingInfo:
  | b-prim(name :: String) # Some "primitive" value supplied by the initial environment
  | b-dict(dict :: SD.StringDict) # Some module supplied by the initial environment
  | b-exp(exp :: A.Expr) # This name is bound to some expression that we can't interpret yet
  | b-dot(base :: BindingInfo, name :: String) # A field lookup off some binding that isn't a b-dict
  | b-typ # A type
  | b-import(imp :: A.ImportType) # imported from a module
  | b-unknown # Any unknown value
end

data Binding:
  | e-bind(loc :: Loc, mut :: Boolean, info :: BindingInfo)
end

fun bind-exp(e :: A.Expr, env) -> Option<Binding>:
  cases(A.Expr) e:
    | s-dot(l, o, name) =>
      cases(Option<Binding>) bind-exp(o, env):
        | some(eb) =>
          b = eb.info
          cases(BindingInfo) b:
            | b-dict(dict) =>
              if dict.has-key(name.key()): some(e-bind(A.dummy-loc, false, dict.get-value(name.key())))
              else: some(e-bind(A.dummy-loc, false, b-dot(b, name)))
              end
            | else => some(e-bind(A.dummy-loc, false, b-dot(b, name)))
          end
        | none => none
      end
    | s-id(_, name) =>
      if env.has-key(name.key()): some(env.get-value(name.key()))
      else: none
      end
    | s-id-var(_, name) =>
      if env.has-key(name.key()): some(env.get-value(name.key()))
      else: none
      end
    | s-id-letrec(_, name, _) =>
      if env.has-key(name.key()): some(env.get-value(name.key()))
      else: none
      end
    | else => some(e-bind(A.dummy-loc, false, b-exp(e)))
  end
end

fun bind-or-unknown(e :: A.Expr, env) -> BindingInfo:
  cases(Option<Binding>) bind-exp(e, env) block:
    | none => b-unknown
    | some(b) =>
      when not(is-e-bind(b)) block:
        print-error("b isn't a binding for expr " + string-substring(torepr(e), 0, 100))
        print-error(b)
      end
      b.info
  end
end

fun binding-type-env-from-env(env):
  for SD.fold-keys(acc from SD.make-string-dict(), name from env.globals.types):
    acc.set(A.s-type-global(name).key(), e-bind(A.dummy-loc, false, b-typ))
  end
end
fun binding-env-from-env(env):
  for SD.fold-keys(acc from SD.make-string-dict(), name from env.globals.values):
    acc.set(A.s-global(name).key(), e-bind(A.dummy-loc, false, b-prim(name)))
  end
end

fun default-env-map-visitor<a, c>(
    initial-env :: a,
    initial-type-env :: c,
    bind-handlers :: {
        s-letrec-bind :: (A.LetrecBind, a -> a),
        s-let-bind :: (A.LetBind, a -> a),
        s-bind :: (A.Bind, a -> a),
        s-header :: (A.Header, a, c -> { val-env :: a, type-env :: c }),
        s-type-let-bind :: (A.TypeLetBind, a, c -> { val-env :: a, type-env :: c }),
        s-param-bind :: (Loc, A.Name, c -> c)
      }
    ):
  A.default-map-visitor.{
    env: initial-env,
    type-env: initial-type-env,
    method s-program(self, l, _provide, _provide-types, provides, imports, body):
      visit-provide = _provide.visit(self)
      visit-provide-types = _provide-types.visit(self)
      visit-imports = for map(i from imports):
        i.visit(self)
      end
      new-envs = { val-env: self.env, type-env: self.type-env }
      imported-envs = for fold(acc from new-envs, i from visit-imports):
        bind-handlers.s-header(i, acc.val-env, acc.type-env)
      end
      visit-body = body.visit(self.{env: imported-envs.val-env, type-env: imported-envs.type-env })
      # MARK(joe/ben)
      A.s-program(l, visit-provide, visit-provide-types, provides, visit-imports, visit-body)
    end,
    method s-type-let-expr(self, l, binds, body, blocky):
      new-envs = { val-env: self.env, type-env: self.type-env }
      bound-env = for lists.fold(acc from new-envs.{ bs: [list: ] }, b from binds):
        updated = bind-handlers.s-type-let-bind(b, acc.val-env, acc.type-env)
        visit-envs = self.{ env: updated.val-env, type-env: updated.type-env }
        new-bind = b.visit(visit-envs)
        updated.{ bs: link(new-bind, acc.bs) }
      end
      A.s-type-let-expr(l, bound-env.bs.reverse(), body.visit(self.{ env: bound-env.val-env, type-env: bound-env.type-env }), blocky)
    end,
    method s-let-expr(self, l, binds, body, blocky):
      bound-env = for fold(acc from { e: self.env, bs : [list: ] }, b from binds):
        new-bind = b.visit(self.{env : acc.e})
        this-env = bind-handlers.s-let-bind(new-bind, acc.e)
        {
          e: this-env,
          bs: link(new-bind, acc.bs)
        }
      end
      visit-binds = bound-env.bs.reverse()
      visit-body = body.visit(self.{env: bound-env.e})
      A.s-let-expr(l, visit-binds, visit-body, blocky)
    end,
    method s-letrec(self, l, binds, body, blocky):
      bind-env = for fold(acc from self.env, b from binds):
        bind-handlers.s-letrec-bind(b, acc)
      end
      new-visitor = self.{env: bind-env}
      visit-binds = binds.map(_.visit(new-visitor))
      visit-body = body.visit(new-visitor)
      A.s-letrec(l, visit-binds, visit-body, blocky)
    end,
    method s-lam(self, l, name, params, args, ann, doc, body, _check-loc, _check, blocky):
      new-type-env = for lists.fold(acc from self.type-env, param from params):
        bind-handlers.s-param-bind(l, param, acc)
      end
      with-params = self.{type-env: new-type-env}
      new-args = args.map(_.visit(with-params))
      args-env = for lists.fold(acc from with-params.env, new-arg from args):
        bind-handlers.s-bind(new-arg, acc)
      end
      with-args = with-params.{env: args-env}
      new-body = body.visit(with-args)
      new-check = with-args.option(_check)
      A.s-lam(l, name, params, new-args, ann.visit(with-args), doc, new-body, _check-loc, new-check, blocky)
    end,
    method s-cases-else(self, l, typ, val, branches, _else, blocky):
      A.s-cases-else(l, typ.visit(self), val.visit(self), branches.map(_.visit(self)), _else.visit(self), blocky)
    end,
    method s-cases-branch(self, l, pat-loc, name, args, body):
      new-args = args.map(_.visit(self))
      args-env = for lists.fold(acc from self.env, arg from args.map(_.bind)):
        bind-handlers.s-bind(arg, acc)
      end
      A.s-cases-branch(l, pat-loc, name, new-args, body.visit(self.{env: args-env}))
    end,
    method s-singleton-cases-branch(self, l, pat-loc, name, body):
      A.s-singleton-cases-branch(l, pat-loc, name, body.visit(self))
    end,
    method s-data-expr(self, l, name, namet, params, mixins, variants, shared-members, _check-loc, _check):
      new-type-env = for lists.fold(acc from self.type-env, param from params):
        bind-handlers.s-param-bind(l, param, acc)
      end
      with-params = self.{type-env: new-type-env}
      A.s-data-expr(l, name, namet.visit(with-params), params,
        mixins.map(_.visit(with-params)), variants.map(_.visit(with-params)),
        shared-members.map(_.visit(with-params)), _check-loc, with-params.option(_check))
    end,
    method s-method(self, l, name, params, args, ann, doc, body, _check-loc, _check, blocky):
      new-type-env = for lists.fold(acc from self.type-env, param from params):
        bind-handlers.s-param-bind(l, param, acc)
      end
      with-params = self.{type-env: new-type-env}
      new-args = args.map(_.visit(with-params))
      args-env = for lists.fold(acc from with-params.env, arg from new-args):
        bind-handlers.s-bind(arg, acc)
      end
      new-body = body.visit(with-params.{env: args-env})
      new-check = with-params.{env: args-env}.option(_check)
      A.s-method(l, params, new-args, ann.visit(with-params.{env: args-env}), doc, new-body, _check-loc, new-check)
    end
  }
end


fun default-env-iter-visitor<a, c>(
    initial-env :: a,
    initial-type-env :: c,
    bind-handlers :: {
        s-letrec-bind :: (A.LetrecBind, a -> a),
        s-let-bind :: (A.LetBind, a -> a),
        s-bind :: (A.Bind, a -> a),
        s-header :: (A.Header, a, c -> { val-env :: a, type-env :: c }),
        s-type-let-bind :: (A.TypeLetBind, a, c -> { val-env :: a, type-env :: c }),
        s-param-bind :: (Loc, A.Name, c -> c)
      }
    ):
  A.default-iter-visitor.{
    env: initial-env,
    type-env: initial-type-env,

    method s-program(self, l, _provide, _provide-types, provides, imports, body):
      if _provide.visit(self) and _provide-types.visit(self):
        new-envs = { val-env: self.env, type-env: self.type-env }
        imported-envs = for fold(acc from new-envs, i from imports):
          bind-handlers.s-header(i, acc.val-env, acc.type-env)
        end
        new-visitor = self.{ env: imported-envs.val-env, type-env: imported-envs.type-env }
        lists.all(_.visit(new-visitor), imports) and body.visit(new-visitor)
        # MARK(joe/ben): provides
      else:
        false
      end
    end,
    method s-type-let-expr(self, l, binds, body, blocky):
      new-envs = { val-env: self.env, type-env: self.type-env }
      bound-env = for lists.fold-while(acc from new-envs.{ bs: true }, b from binds):
        updated = bind-handlers.s-type-let-bind(b, acc.val-env, acc.type-env)
        visit-envs = self.{ env: updated.val-env, type-env: updated.type-env }
        new-bind = b.visit(visit-envs)
        if new-bind:
          E.left(updated.{ bs: true })
        else:
          E.right(updated.{ bs: false})
        end
      end
      bound-env.bs and body.visit(self.{ env: bound-env.val-env, type-env: bound-env.type-env })
    end,
    method s-let-expr(self, l, binds, body, blocky):
      bound-env = for lists.fold-while(acc from { e: self.env, bs: true }, b from binds):
        this-env = bind-handlers.s-let-bind(b, acc.e)
        new-bind = b.visit(self.{env : acc.e})
        if new-bind:
          E.left({ e: this-env, bs: true })
        else:
          E.right({ e: this-env, bs: false })
        end
      end
      bound-env.bs and body.visit(self.{env: bound-env.e})
    end,
    method s-letrec(self, l, binds, body, blocky):
      bind-env = for lists.fold(acc from self.env, b from binds):
        bind-handlers.s-letrec-bind(b, acc)
      end
      new-visitor = self.{env: bind-env}
      continue-binds = for lists.fold-while(acc from true, b from binds):
        if b.visit(new-visitor): E.left(true) else: E.right(false) end
      end
      continue-binds and body.visit(new-visitor)
    end,
    method s-lam(self, l, name, params, args, ann, doc, body, _check-loc, _check, blocky):
      new-type-env = for lists.fold(acc from self.type-env, param from params):
        bind-handlers.s-param-bind(l, param, acc)
      end
      with-params = self.{type-env: new-type-env}
      visit-args = lists.all(_.visit(with-params), args)
      args-env = for lists.fold(acc from with-params.env, arg from args):
        bind-handlers.s-bind(arg, acc)
      end
      with-args = with-params.{env: args-env}
      visit-args and
        ann.visit(with-args) and
        body.visit(with-args) and
        with-args.option(_check)
    end,
    method s-cases-else(self, l, typ, val, branches, _else):
      typ.visit(self)
      and val.visit(self)
      and lists.all(_.visit(self), branches)
      and _else.visit(self)
    end,
    method s-cases-branch(self, l, pat-loc, name, args, body):
      visit-args = lists.all(_.visit(self), args)
      args-env = for lists.fold(acc from self.env, arg from args.map(_.bind)):
        bind-handlers.s-bind(arg, acc)
      end
      visit-args
      and body.visit(self.{env: args-env})
    end,
    # s-singleton-cases-branch introduces no new bindings, so default visitor is fine
    method s-data-expr(self, l, name, namet, params, mixins, variants, shared-members, _check-loc, _check):
      new-type-env = for lists.fold(acc from self.type-env, param from params):
        bind-handlers.s-param-bind(l, param, acc)
      end
      with-params = self.{type-env: new-type-env}
      namet.visit(with-params)
      and lists.all(_.visit(with-params), mixins)
      and lists.all(_.visit(with-params), variants)
      and lists.all(_.visit(with-params), shared-members)
      and with-params.option(_check)
    end,
    method s-method(self, l, params, args, ann, doc, body, _check-loc, _check):
      new-type-env = for lists.fold(acc from self.type-env, param from params):
        bind-handlers.s-param-bind(l, param, acc)
      end
      with-params = self.{type-env: new-type-env}
      args-env = for lists.fold(acc from self.env, arg from args):
        bind-handlers.s-bind(arg, acc)
      end
      lists.all(_.visit(with-params), args) and
        ann.visit(with-params.{env: args-env}) and
        body.visit(with-params.{env: args-env}) and
        with-params.{env: args-env}.option(_check)
    end
  }
end

binding-handlers = {
  method s-header(_, imp, env, type-env):
    with-vname = env.set(imp.vals-name.key(), e-bind(imp.l, false, b-unknown))
    with-tname = type-env.set(imp.types-name.key(), e-bind(imp.l, false, b-typ))
    with-vnames = for fold(venv from with-vname, v from imp.values):
      venv.set(v.key(), e-bind(imp.l, false, b-import(imp.import-type)))
    end
    with-tnames = for fold(tenv from with-tname, t from imp.types):
      tenv.set(t.key(), e-bind(imp.l, false, b-import(imp.import-type)))
    end
    {
      val-env: with-vnames,
      type-env: with-tnames
    }
  end,
  method s-param-bind(_, l, param, type-env):
    type-env.set(param.key(), e-bind(l, false, b-typ))
  end,
  method s-type-let-bind(_, tlb, env, type-env):
    cases(A.TypeLetBind) tlb:
      | s-type-bind(l, name, ann) =>
        {
          val-env: env,
          type-env: type-env.set(name.key(), e-bind(l, false, b-typ))
        }
      | s-newtype-bind(l, tname, bname) =>
        {
          val-env: env.set(bname.key(), e-bind(l, false, b-unknown)),
          type-env: type-env.set(tname.key(), e-bind(l, false, b-typ))
        }
    end
  end,
  method s-let-bind(_, lb, env):
    cases(A.LetBind) lb:
      | s-let-bind(l2, bind, val) =>
        env.set(bind.id.key(), e-bind(l2, false, bind-or-unknown(val, env)))
      | s-var-bind(l2, bind, val) =>
        env.set(bind.id.key(), e-bind(l2, true, b-unknown))
    end
  end,
  method s-letrec-bind(_, lrb, env):
    env.set(lrb.b.id.key(),
      e-bind(lrb.l, false, bind-or-unknown(lrb.value, env)))
  end,
  method s-bind(_, b, env):
    env.set(b.id.key(), e-bind(b.l, false, b-unknown))
  end
}
fun binding-env-map-visitor(initial-env):
  default-env-map-visitor(binding-env-from-env(initial-env), binding-type-env-from-env(initial-env), binding-handlers)
end
fun binding-env-iter-visitor(initial-env):
  default-env-iter-visitor(binding-env-from-env(initial-env), binding-type-env-from-env(initial-env), binding-handlers)
end

fun link-list-visitor(initial-env):
  binding-env-map-visitor(initial-env).{
    method s-app(self, l, f, args):
      if A.is-s-dot(f) and (f.field == "_plus"):
        target = f.obj
        cases(A.Expr) target:
          | s-app(l2, lnk, _args) =>
            cases(BindingInfo) bind-or-unknown(lnk, self.env):
              | b-prim(n) =>
                if n == "list:link":
                  A.s-app(l2, lnk, [list: _args.first,
                      A.s-app(l, A.s-dot(f.l, _args.rest.first, f.field), args).visit(self)])
                else if n == "list:empty":
                  args.first.visit(self)
                else:
                  A.s-app(l, f.visit(self), args.map(_.visit(self)))
                end
              | else =>
                A.s-app(l, f.visit(self), args.map(_.visit(self)))
            end
          | s-id(_, _) =>
            cases(BindingInfo) bind-or-unknown(target, self.env):
              | b-prim(name) =>
                if (name == "list:empty"):
                  args.first.visit(self)
                else:
                  A.s-app(l, f.visit(self), args.map(_.visit(self)))
                end
              | else =>
                A.s-app(l, f.visit(self), args.map(_.visit(self)))
            end
          | s-dot(_, _, _) =>
            cases(BindingInfo) bind-or-unknown(target, self.env):
              | b-prim(name) =>
                if (name == "list:empty"):
                  args.first.visit(self)
                else:
                  A.s-app(l, f.visit(self), args.map(_.visit(self)))
                end
              | else =>
                A.s-app(l, f.visit(self), args.map(_.visit(self)))
            end
          | else =>
            A.s-app(l, f.visit(self), args.map(_.visit(self)))
        end
      else:
        A.s-app(l, f.visit(self), args.map(_.visit(self)))
      end
    end
  }
end

fun bad-assignments(initial-env, ast) block:
  var errors = [list: ] # THE MUTABLE LIST OF ERRORS
  fun add-error(err): errors := err ^ link(_, errors) end
  ast.visit(binding-env-iter-visitor(initial-env).{
    method s-assign(self, loc, id, value) block:
      cases(Option<Binding>) bind-exp(A.s-id(loc, id), self.env):
        | none => nothing
        | some(b) =>
          when not(b.mut):
            add-error(CS.bad-assignment(id.toname(), loc, b.loc))
          end
      end
      value.visit(self)
    end,
  })
  errors
end

inline-lams = A.default-map-visitor.{
  method s-app(self, loc, f, exps):
    cases(A.Expr) f:
      | s-lam(l, _, _, args, ann, _, body, _, _, _) =>
        if (args.length() == exps.length()):
          a = A.global-names.make-atom("inline_body")
          let-binds = for lists.map2(arg from args, exp from exps):
            A.s-let-bind(arg.l, arg, exp.visit(self))
          end
          cases(A.Ann) ann:
            | a-blank => A.s-let-expr(l, let-binds, body.visit(self), false)
            | a-any => A.s-let-expr(l, let-binds, body.visit(self), false)
            | else =>
              A.s-let-expr(l,
                let-binds
                  + [list: A.s-let-bind(body.l, A.s-bind(l, false, a, ann), body.visit(self))],
                A.s-id(l, a),
                false)
          end
        else:
          A.s-app(loc, f.visit(self), exps.map(_.visit(self)))
        end
      | else => A.s-app(loc, f.visit(self), exps.map(_.visit(self)))
    end
  end
}

data Scope:
  | no-s

  | fun-s(id :: A.Name)
  | method-s(self-id :: A.Name, name :: String)

  | partial-fun-s(id :: A.Name)
  | partial-method-s(name :: String)
end

# set-recursive-visitor is to replace s-app with s-app-enhanced with correct is-recursive
# but with incorrect is-tail (all false)
# postcondition: no s-app
set-recursive-visitor = A.default-map-visitor.{
  scope: no-s,

  method clear-scope(self):
    self.{scope: no-s}
  end,

  method is-recursive(self, f :: A.Expr) -> Boolean:
    doc: "Return a Boolean indicating whether a call with `f` is recursive or not"
    cases (Scope) self.scope:
      | fun-s(id) => A.is-s-id-letrec(f) and (f.id == id)
      | method-s(self-id, name) => false # TODO(Oak, 15 Jan 2016): Don't care about method for now

      | no-s => false
      | partial-method-s(_) => false # Do not actually find a method: `{ a : lam(): id(1) end }`
      | partial-fun-s(_) => raise("Error while querying: after partial-fun-s should immediately be fun-s")
    end
  end,

  method activate-fun(self):
    doc: "Activate fun-s"
    cases (Scope) self.scope:
      | partial-fun-s(id) => self.{scope: fun-s(id)}

      | no-s => self # no letrec, meaning it's just normal lambda: `lam(x): x + 1 end(5)`, for example
      | fun-s(_) => self.clear-scope() # lam in function: `fun foo() lam(): 1 end end`
      | method-s(_, _) => self.clear-scope() # lam in method: `{ foo(self): lam(): 1 end end }`
      | partial-method-s(_) => self.clear-scope() # lam in object: `{ a : lam(): id(1) end }`
    end
  end,

  method collect-fun-name(self, binding :: A.LetrecBind):
    doc: "Return an environment with a binding containing function's name"
    if A.is-s-lam(binding.value):
      self.{scope: partial-fun-s(binding.b.id)}
    else:
      self
    end
  end,

  method collect-method-self(self, self-bind :: A.Bind):
    doc: "Return an environment with method's self id"
    cases (Scope) self.scope:
      | partial-method-s(name) => self.{scope: method-s(self-bind.id, name)}

      | no-s => self.clear-scope() # `method(self): 1 end`
      | fun-s(_) => self.clear-scope() # fun foo(): method(self): 1 end end
      | method-s(_, _) => self.clear-scope() # { a(self1): method(self2): 1 end end }
      | partial-fun-s(_) => raise("Error while collecting self: after partial-fun-s should immediately be fun-s")
    end
  end,

  method collect-method-name(self, method-name :: String):
    doc: "Return an environment with a method's name"
    self.{scope: partial-method-s(method-name)}
  end,


  method s-app(self, l, f, exps):
    A.s-app-enriched(
      l,
      f.visit(self),
      exps.map(_.visit(self)),
      A.app-info-c(self.is-recursive(f), false))
  end,
  method s-lam(self, l, name, params, args, ann, doc, body, _check-loc, _check, blocky):
    A.s-lam(
      l,
      name,
      params.map(_.visit(self.clear-scope())),
      args.map(_.visit(self.clear-scope())),
      ann.visit(self.clear-scope()),
      doc,
      body.visit(self.activate-fun()),
      _check-loc,
      self.clear-scope().option(_check),
      blocky)
  end,
  method s-method(self, l, name, params, args, ann, doc, body, _check-loc, _check, blocky) block:
    A.s-method(
      l,
      name,
      params.map(_.visit(self)),
      args.map(_.visit(self)),
      ann.visit(self),
      doc,
      body.visit(self.collect-method-self(args.first)),
      _check-loc,
      self.option(_check),
      blocky
      )
  end,
  method s-letrec(self, l, binds, body, blocky):
    A.s-letrec(
      l,
      binds.map(lam(bind :: A.LetrecBind): bind.visit(self.collect-fun-name(bind)) end),
      body.visit(self),
      blocky)
  end,
  method s-data-field(self, l, name, value):
    A.s-data-field(l, name, value.visit(self.collect-method-name(name)))
  end,
}

fun is-stateful-ann(ann :: A.Ann) -> Boolean:
  doc: ```
       Return whether `ann` is a stateful annotation or not. For now, consider
       all refinements as potentially could be stateful.
       ```
  # TODO(Oak, 26 Jan 2016): make sure below are correct when static type checker lands
  cases (A.Ann) ann:
    | a-blank => false
    | a-any(l) => false
    | a-name(_, _) => false
    | a-type-var(_, _) => false 
    | a-arrow(_, args, ret, _) => false
    | a-arrow-argnames(_, args, ret, _) => false
    | a-method(_, args, ret, _) => false
    | a-record(_, fields) => fields.map(_.ann).all(is-stateful-ann)
    | a-tuple(_, fields) => fields.all(is-stateful-ann)
    | a-app(_, inner, args) => is-stateful-ann(inner)
    | a-pred(_, _, _) => true # TODO(Oak, 21 Jan 2016): true for now. Could refine later
    | a-dot(_, _, _) => true # TODO(Oak, 7 Feb 2016): true for now. Could refine later
    | a-checked(_, _) => raise("NYI")
  end
end

# set-tail-visitor is to correct is-tail in s-app-enriched
# precondition: no s-app
set-tail-visitor = A.default-map-visitor.{
  is-tail: false,

  method s-module(self, l, answer, dm, dv, dt, checks):
    no-tail = self.{is-tail: false}
    A.s-module(
      l,
      answer.visit(no-tail),
      dm.map(_.visit(no-tail)),
      dv.map(_.visit(no-tail)),
      dt.map(_.visit(no-tail)),
      checks.visit(no-tail))
  end,

  # skip s-num, s-frac, s-str, s-undefined, s-bool, s-id, s-id-var, s-id-letrec, s-srcloc
  # because it has no s-app-enriched

  # skip s-type-let-expr because all positions which could have s-app-enriched could be in the tail position

  method s-let-expr(self, l, binds, body, blocky):
    A.s-let-expr(
      l,
      binds.map(_.visit(self.{is-tail: false})),
      body.visit(self),
      blocky)
  end,

  method s-letrec(self, l, binds, body, blocky):
    A.s-letrec(
      l,
      binds.map(_.visit(self.{is-tail: false})),
      body.visit(self),
      blocky)
  end,

  # skip s-data-expr because it couldn't be at the tail position

  # skip s-if-else because all positions which could have s-app-enriched could be in the tail position

  method s-if-branch(self, l, test, body):
    A.s-if-branch(l, test.visit(self.{is-tail: false}), body.visit(self))
  end,

  method s-cases-else(self, l, typ, val, branches, _else, blocky):
    A.s-cases-else(l, typ.visit(self), val.visit(self.{is-tail: false}), branches.map(_.visit(self)), _else.visit(self), false)
  end,

  method s-block(self, l, stmts):
    len = stmts.length() # can be sure that len >= 1
    splitted = stmts.split-at(len - 1)
    A.s-block(
      l,
      splitted.prefix.map(_.visit(self.{is-tail: false})) +
      splitted.suffix.map(_.visit(self)))
  end,

  method s-check-expr(self, l, expr, ann):
    A.s-check-expr(
      l,
      expr.visit(self.{is-tail: false}),
      ann.visit(self.{is-tail: false}))
  end,

  method s-lam(self, l, name, params, args, ann, doc, body, _check-loc, _check, blocky):
    A.s-lam(
      l,
      name,
      params.map(_.visit(self.{is-tail: false})),
      args.map(_.visit(self.{is-tail: false})),
      ann.visit(self.{is-tail: false}),
      doc,
      body.visit(self.{is-tail: not(is-stateful-ann(ann))}),
      _check-loc,
      self.{is-tail: false}.option(_check),
      blocky)
  end,

  method s-method(self, l, name, params, args, ann, doc, body, _check-loc, _check, blocky):
    A.s-method(
      l,
      name,
      params.map(_.visit(self.{is-tail: false})),
      args.map(_.visit(self.{is-tail: false})),
      ann.visit(self.{is-tail: false}),
      doc,
      body.visit(self.{is-tail: not(is-stateful-ann(ann))}),
      _check-loc,
      self.{is-tail: false}.option(_check),
      blocky)
  end,

  method s-array(self, l, values):
    A.s-array(l, values.map(_.visit(self.{is-tail: false})))
  end,

  method s-app-enriched(self, l, f, exps, app-info):
    A.s-app-enriched(
      l,
      f.visit(self.{is-tail: false}),
      exps.map(_.visit(self.{is-tail: false})),
      A.app-info-c(app-info.is-recursive, self.is-tail))
  end,

  method s-prim-app(self, l, _fun, args, app-info):
    A.s-prim-app(l, _fun, args.map(_.visit(self.{is-tail: false})), app-info)
  end,

  # skip s-instantiate because all positions which could have s-app-enriched could be in the tail position

  method s-dot(self, l, obj, field):
    A.s-dot(l, obj.visit(self.{is-tail: false}), field)
  end,

  # skip s-ref because it has no s-app-enriched -- what is s-ref anyway

  method s-get-bang(self, l, obj, field):
    A.s-get-bang(l, obj.visit(self.{is-tail: false}), field)
  end,

  method s-assign(self, l, id, value):
    A.s-assign(l, id.visit(self.{is-tail: false}), value.visit(self.{is-tail: false}))
  end,

  method s-obj(self, l, fields):
    A.s-obj(l, fields.map(_.visit(self.{is-tail: false})))
  end,

  method s-update(self, l, supe, fields):
    A.s-update(l, supe.visit(self.{is-tail: false}), fields.map(_.visit(self.{is-tail: false})))
  end,

  method s-extend(self, l, supe, fields):
    A.s-extend(l, supe.visit(self.{is-tail: false}), fields.map(_.visit(self.{is-tail: false})))
  end
}

fun value-delays-exec-of(name, expr):
  A.is-s-lam(expr) or A.is-s-method(expr)
end

letrec-visitor = A.default-map-visitor.{
  env: SD.make-string-dict(),
  method s-letrec(self, l, binds, body, blocky):
    bind-envs = for map2(b1 from binds, i from range(0, binds.length())) block:
      rhs-is-delayed = value-delays-exec-of(b1.b.id, b1.value)
      acc = self.env.unfreeze()
      for each2(b2 from binds, j from range(0, binds.length())):
        key = b2.b.id.key()
        if i < j:
          acc.set-now(key, false)
        else if i == j:
          acc.set-now(key, rhs-is-delayed)
        else:
          acc.set-now(key, true)
        end
      end
      acc.freeze()
    end
    new-binds = for map2(b from binds, bind-env from bind-envs):
      b.visit(self.{ env: bind-env })
    end
    body-env = bind-envs.last().set(binds.last().b.id.key(), true)
    new-body = body.visit(self.{ env: body-env })
    A.s-letrec(l, new-binds, new-body, blocky)
  end,
  method s-id-letrec(self, l, id, _):
    A.s-id-letrec(l, id, self.env.get-value(id.key()))
  end
}

fun make-renamer(replacements :: SD.StringDict):
  A.default-map-visitor.{
    method s-atom(self, base, serial):
      a = A.s-atom(base, serial)
      k = a.key()
      if replacements.has-key(k):
        replacements.get-value(k)
      else:
        a
      end
    end
  }
end

fun wrap-extra-imports(p :: A.Program, env :: CS.ExtraImports) -> A.Program:
  expr = p.block
  cases(CS.ExtraImports) env:
    | extra-imports(imports) =>
      #|
         NOTE(Ben): I've moved the existing p.imports *after* these generated imports,
         so that any user-requested imports have to coexist in the global environment,
         rather than globals having to coexist in the user's environment.
         Additionally, this allows for better srcloc reporting: suppose the user's program says
           `import some from option`
         which is already existing in the global scope.  The global import will have
         srcloc=A.dummy-loc, but the deliberate import will have srcloc within the file,
         which will ensure the error message refers to that explicit location.
         (I can't change how `resolve-scope:add-value-name` or `resolve-scope:make-import-atom-for`
         handle this case, because we haven't finished resolving names to know whether the name
         collision is acceptable or not.)
      |#
      l = A.dummy-loc
      full-imports = for fold(lst from empty, i from imports):
          name-to-use = if i.as-name == "_": A.global-names.make-atom("$extra-import") else: A.s-name(l, i.as-name) end
          ast-dep = cases(CS.Dependency) i.dependency:
            | builtin(name) => A.s-const-import(p.l, name)
            | dependency(protocol, args) => A.s-special-import(p.l, protocol, args)
          end
          import-line = A.s-import(p.l, ast-dep, name-to-use)
          include-line = 
            A.s-include-from(p.l, [list: name-to-use],
              i.values.map(lam(v):
                A.s-include-name(l, A.s-module-ref(l, [list: A.s-name(l, v)], none))
              end) +
              i.types.map(lam(t):
                A.s-include-type(l, A.s-module-ref(l, [list: A.s-name(l, t)], none))
              end))
          link(import-line, link(include-line, empty)) + lst
        end + p.imports
      A.s-program(p.l, p._provide, p.provided-types, p.provides, full-imports, p.block)
  end
end

fun import-to-dep(imp):
  cases(A.ImportType) imp:
    # crossover compatibility
    | s-const-import(_, modname) => CS.builtin(modname)
    | s-special-import(_, protocol, args) => CS.dependency(protocol, args)
  end
end

fun some-pred<a>(pred :: (a -> Boolean), o :: Option<a>) -> a:
  cases(Option) o block:
    | none => raise("Expected some but got none")
    | some(exp) =>
      when not(pred(exp)):
        raise("Predicate failed for " + torepr(exp))
      end
      exp
  end
end

is-s-data-expr = A.is-s-data-expr

is-t-name = T.is-t-name
type NameChanger = (T.Type%(is-t-name) -> T.Type)

fun get-name-spec-key(ns :: A.NameSpec):
  cases(A.NameSpec) ns block:
    | s-star(_, _) => raise("Should not get star name-specs in type-checker")
    | s-module-ref(_, path, _) =>
      when path.length() <> 1: raise("Path for a module-ref should always be length 1") end
      path.first.key()
    | s-local-ref(l, name, as-name) =>
      name.key()
  end
end
fun get-name-spec-key-and-name(ns :: A.NameSpec):
  cases(A.NameSpec) ns block:
    | s-star(_, _) => raise("Should not get star name-specs in type-checker")
    | s-module-ref(_, path, as-name) =>
      when is-none(as-name): raise("Should always have an as-name post resolve-scope") end
      when path.length() <> 1: raise("Path for a module-ref should always be length 1") end
      { path.first.key(); as-name.value.toname() }
  end
end
fun get-name-spec-atom-and-name(ns :: A.NameSpec):
  cases(A.NameSpec) ns block:
    | s-star(_, _) => raise("Should not get star name-specs in type-checker")
    | s-module-ref(_, path, as-name) =>
      when is-none(as-name): raise("Should always have an as-name post resolve-scope") end
      when path.length() <> 1: raise("Path for a module-ref should always be length 1") end
      { path.first; as-name.value.toname() }
  end
end

fun get-named-provides(resolved :: CS.NameResolution, uri :: URI, compile-env :: CS.CompileEnvironment) -> CS.Provides:
  fun collect-shared-fields(vs :: List<A.Variant>) -> SD.StringDict<T.Type>:
    if is-empty(vs):
      [SD.string-dict: ]
    else:
      init-members = members-to-t-members(vs.first.with-members)
      vs.rest.foldl(lam(v, shared-members):
        v.with-members.foldl(lam(m, shadow shared-members):
          if shared-members.has-key(m.name):
            existing-mem-type = shared-members.get-value(m.name)
            this-mem-type = member-to-t-member(m)
            if existing-mem-type == this-mem-type:
              shared-members
            else:
              shared-members.remove(m.name)
            end
          else:
            shared-members
          end
        end, shared-members)
      end, init-members)
    end
  end

  fun v-members-to-t-members(ms):
    ms.foldr(lam(m, members):
      cases(A.VariantMember) m:
        | s-variant-member(l, kind, bind) =>
          typ = if A.is-s-mutable(kind):
            T.t-ref(ann-to-typ(bind.ann), l, false)
          else:
            ann-to-typ(bind.ann)
          end
          link({bind.id.toname(); typ}, members)
      end
    end, empty)
  end

  fun member-to-t-member(m):
    cases(A.Member) m:
      | s-data-field(l, name, val) =>
        T.t-top(l, false)
      | s-mutable-field(l, name, ann, val) =>
        T.t-ref(ann-to-typ(ann), false)
      | s-method-field(l, name, params, args, ann, _, _, _, _, _) =>
        arrow-part =
          T.t-arrow(map(ann-to-typ, map(_.ann, args)), ann-to-typ(ann), l, false)
        if is-empty(params): arrow-part
        else:
          tvars = for map(p from params): T.t-var(p, l, false) end
          T.t-forall(tvars, arrow-part, l, false)
        end
    end
  end

  fun members-to-t-members(ms):
    ms.foldl(lam(m, members):
      cases(A.Member) m:
        | s-data-field(l, name, val) =>
          members.set(name, member-to-t-member(m))
        | s-mutable-field(l, name, ann, val) =>
          members.set(name, member-to-t-member(m))
        | s-method-field(l, name, params, args, ann, _, _, _, _, _) =>
          members.set(name, member-to-t-member(m))
      end
    end, [SD.string-dict: ])
  end

  # TODO(MATT): a-blank should have location
  fun ann-to-typ(a :: A.Ann) -> T.Type:
    cases(A.Ann) a:
      | a-blank => T.t-top(A.dummy-loc, false)
      | a-any(l) => T.t-top(l, false)
      | a-name(l, id) =>
        cases(A.Name) id:
          | s-type-global(name) =>
            cases(Option<String>) compile-env.globals.types.get(name):
              | none =>
                raise("Name not found in globals.types: " + name)
              | some(origin) =>
                # ```include from string-dict: type StringDict as SD end```
                T.t-name(T.module-uri(origin.uri-of-definition), origin.original-name, l, false)
            end
          | s-atom(_, _) => T.t-name(T.module-uri(uri), id, l, false)
          | else => raise("Bad name found in ann-to-typ: " + id.key())
        end
      | a-type-var(l, id) =>
        T.t-var(id, l, false)
      | a-arrow(l, args, ret, use-parens) =>
        T.t-arrow(map(ann-to-typ, args), ann-to-typ(ret), l, false)
      | a-arrow-argnames(l, args, ret, use-parens) =>
        T.t-arrow(map({(arg): ann-to-typ(arg.ann)}, args), ann-to-typ(ret), l, false)
      | a-method(l, args, ret) =>
        raise("Cannot provide a raw method")
      | a-record(l, fields) =>
        T.t-record(fields.foldl(lam(f, members):
          members.set(f.name, ann-to-typ(f.ann))
        end, [SD.string-dict: ]), l, false)
      | a-tuple(l, fields) =>
        T.t-tuple(map(ann-to-typ, fields), l, false)
      | a-app(l, ann, args) =>
        T.t-app(ann-to-typ(ann), map(ann-to-typ, args), l, false)
      | a-pred(l, ann, exp) =>
        # TODO(joe): give more info than this to type checker?  only needed dynamically, right?
        ann-to-typ(ann)
      | a-dot(l, obj, field) =>
        # TODO(joe): maybe-b = resolved.module-bindings.get-now(obj.key())
        # Then use the information to provide the right a-dot type by looking
        # it up on the module.
        T.t-top(l, false)
      | a-checked(checked, residual) =>
        raise("a-checked should only be generated by the type-checker")
    end
  end
  fun data-expr-to-datatype(exp :: A.Expr % (is-s-data-expr)) -> T.DataType:
    cases(A.Expr) exp:
      | s-data-expr(l, name, _, params, _, variants, shared-members, _, _) =>

        tvars = for map(tvar from params):
          T.t-var(tvar, l, false)
        end

        tvariants = for map(tv from variants):
          cases(A.Variant) tv:
            | s-variant(l2, constr-loc, vname, members, with-members) =>
              T.t-variant(
                vname,
                v-members-to-t-members(members),
                members-to-t-members(with-members),
                l2)
            | s-singleton-variant(l2, vname, with-members) =>
              T.t-singleton-variant(
                vname,
                members-to-t-members(with-members),
                l2)
          end
        end

        shared-across-variants = collect-shared-fields(variants)
        shared-fields = members-to-t-members(shared-members)
        all-shared-fields = shared-across-variants.fold-keys(lam(key, all-shared-fields):
          if shared-fields.has-key(key):
            all-shared-fields
          else:
            all-shared-fields.set(key, shared-across-variants.get-value(key))
          end
        end, shared-fields)

        T.t-data(
          name,
          tvars,
          tvariants,
          all-shared-fields,
          l)
    end
  end
  cases(A.Program) resolved.ast:
    | s-program(_, _, _, provide-blocks, _, _) =>
      cases(A.ProvideBlock) provide-blocks.first block:
          # NOTE(joe): assume the provide block is resolved
        | s-provide-block(_, _, provide-specs) =>
          mp-specs = provide-specs.filter(A.is-s-provide-module)
          mod-provides = for fold(mp from [SD.string-dict:], m from mp-specs):
            cases(A.NameSpec) m.name-spec:
              | s-remote-ref(l, shadow uri, name, as-name) =>
                mod-info = compile-env.provides-by-uri-value(uri)
                mod-uri = mod-info.modules.get-value(name.toname())
                mp.set(as-name.toname(), mod-uri)
              | s-local-ref(l, name, as-name) =>
                mb = resolved.env.module-bindings.get-value-now(name.key())
                mp.set(as-name.toname(), mb.uri)
              | else => raise("All provides should be resolved to local or remote refs")
            end
          end
          
          vp-specs = provide-specs.filter(A.is-s-provide-name)
          val-provides = for fold(vp from [SD.string-dict:], v from vp-specs):
            cases(A.NameSpec) v.name-spec:
              | s-remote-ref(l, shadow uri, name, as-name) =>
                { origin-name; val-export } = compile-env.resolve-value-by-uri-value(uri, name.toname())
                origin = val-export.origin
                corrected-origin = CS.bind-origin(
                  as-name.l,
                  origin.definition-bind-site,
                  origin.new-definition,
                  origin.uri-of-definition,
                  origin.original-name)
                vp.set(as-name.toname(), CS.v-alias(corrected-origin, origin-name))
              | s-local-ref(l, name, as-name) =>
                vb = resolved.env.bindings.get-value-now(name.key())
                provided-value = cases(CS.ValueBinder) vb.binder:
                  | vb-var => CS.v-var(vb.origin, ann-to-typ(vb.ann))
                  | else => CS.v-just-type(vb.origin, ann-to-typ(vb.ann))
                end
                vp.set(as-name.toname(), provided-value)
            end
          end
          #|
          spy "get-named-provides":
            vp-specs,
            val-provides
          end
          |#

          tp-specs = provide-specs.filter(A.is-s-provide-type)
          typ-provides = for fold(tp from [SD.string-dict:], t from tp-specs):
            cases(A.NameSpec) t.name-spec:
              | s-remote-ref(l, shadow uri, name, as-name) =>
                tp.set(as-name.toname(), T.t-name(T.module-uri(uri), name, l, false))
              | s-local-ref(l, name, as-name) =>
                tb = resolved.env.type-bindings.get-value-now(name.key())
                typ = cases(Option) tb.ann:
                  | none => T.t-top(l, false)
                  | some(target-ann) => ann-to-typ(target-ann)
                end
                tp.set(as-name.toname(), typ)
            end
          end
          
          dp-specs = provide-specs.filter(A.is-s-provide-data)
          data-provides = for fold(dp from [SD.string-dict:], d from dp-specs):
            cases(A.NameSpec) d.name-spec:
              | s-remote-ref(l, shadow uri, name, as-name) =>
                # TODO(joe): do remote lookup here to get a better location than SL.builtin for the origin
                dp.set(as-name.toname(), CS.d-alias(CS.bind-origin(l, SL.builtin(uri), false, uri, name), name.toname()))
              | s-local-ref(l, name, as-name) =>
                exp = resolved.env.datatypes.get-value-now(name.toname())
                dp.set(as-name.toname(), CS.d-type(CS.bind-origin(l, exp.l, true, uri, name), data-expr-to-datatype(exp)))
            end
          end
          provs = CS.provides(
              uri,
              mod-provides,
              val-provides,
              typ-provides,
              data-provides)
          provs
      end
  end
end

fun canonicalize-members(ms :: T.TypeMembers, uri :: URI, tn :: NameChanger) -> T.TypeMembers:
  T.type-member-map(ms, lam(_, typ): canonicalize-names(typ, uri, tn) end)
end

fun canonicalize-fields(ms :: List<{String; T.Type}>, uri :: URI, tn :: NameChanger) -> List<{String; T.Type}>:
  ms.map(lam({name; typ}): {name; canonicalize-names(typ, uri, tn)} end)
end

fun canonicalize-variant(v :: T.TypeVariant, uri :: URI, tn :: NameChanger) -> T.TypeVariant:
  c = canonicalize-members(_, uri, tn)
  cases(T.TypeVariant) v:
    | t-variant(name, fields, with-fields, l) =>
      T.t-variant(name, canonicalize-fields(fields, uri, tn), c(with-fields), l)
    | t-singleton-variant(name, with-fields, l) =>
      T.t-singleton-variant(name, c(with-fields), l)
  end
end

fun canonicalize-data-export(de :: CS.DataExport, uri :: URI, tn :: NameChanger) -> CS.DataExport:
  cases(CS.DataExport) de:
    | d-alias(origin, name) => de
    | d-type(origin, typ) => CS.d-type(origin, canonicalize-data-type(typ, uri, tn))
  end
end

fun canonicalize-data-type(dtyp :: T.DataType, uri :: URI, tn :: NameChanger) -> T.DataType:
  cases(T.DataType) dtyp:
    | t-data(name, params, variants, fields, l) =>
      T.t-data(
          name,
          params,
          map(canonicalize-variant(_, uri, tn), variants),
          canonicalize-members(fields, uri, tn),
          l)
  end
end

# TODO(MATT): add all the correct cases to this
fun canonicalize-names(typ :: T.Type, uri :: URI, transform-name :: NameChanger) -> T.Type:
  c = canonicalize-names(_, uri, transform-name)
  cases(T.Type) typ:
    | t-name(module-name, id, l, _) => transform-name(typ)
    | t-var(id, l, _) => typ
    | t-arrow(args, ret, l, inferred) => T.t-arrow(map(c, args), c(ret), l, inferred)
    | t-tuple(elts, l, inferred) => T.t-tuple(map(c, elts), l, inferred)
    | t-app(onto, args, l, inferred) => T.t-app(c(onto), map(c, args), l, inferred)
    | t-top(l, inferred) => T.t-top(l, inferred)
    | t-bot(l, inferred) => T.t-bot(l, inferred)
    | t-record(fields, l, inferred) =>
      T.t-record(canonicalize-members(fields, uri, transform-name), l, inferred)
    | t-forall(introduces, onto, l, inferred) => T.t-forall(map(c, introduces), c(onto), l, inferred)
    | t-ref(t, l, inferred) => T.t-ref(c(t), l, inferred)
    | t-data-refinement(data-type, variant-name, l, inferred) =>
      T.t-data-refinement(c(data-type), variant-name, l, inferred)
    | t-existential(id, l, _) => typ
  end
end

fun canonicalize-value-export(ve :: CS.ValueExport, uri :: URI, tn):
  cases(CS.ValueExport) ve:
    | v-alias(o, n) => CS.v-alias(o, n)
    | v-just-type(o, t) => CS.v-just-type(o, canonicalize-names(t, uri, tn))
    | v-var(o, t) => CS.v-var(o, canonicalize-names(t, uri, tn))
    | v-fun(o, t, name, flatness) => CS.v-fun(o, canonicalize-names(t, uri, tn), name, flatness)
  end
end

fun find-mod(compile-env, uri) -> Option<String>:
  for find(depkey from compile-env.my-modules.keys-list()):
    other-uri = compile-env.my-modules.get-value(depkey)
    other-uri == uri
  end
end


fun transform-dict-helper(canonicalizer):
  lam(d, uri, transformer):
    for SD.fold-keys(s from [SD.string-dict: ], v from d):
      s.set(v, canonicalizer(d.get-value(v), uri, transformer))
    end
  end
end

transform-value-dict = transform-dict-helper(canonicalize-value-export)
transform-dict = transform-dict-helper(canonicalize-names)
transform-data-dict = transform-dict-helper(canonicalize-data-export)

fun transform-provides(provides, compile-env, transformer):
  cases(CS.Provides) provides:
  | provides(from-uri, modules, values, aliases, data-definitions) =>
    new-vals = transform-value-dict(values, from-uri, transformer)
    new-aliases = transform-dict(aliases, from-uri, transformer)
    new-data-definitions = transform-data-dict(data-definitions, from-uri, transformer)
    CS.provides(from-uri, modules, new-vals, new-aliases, new-data-definitions)
  end
end

fun canonicalize-provides(provides :: CS.Provides, compile-env :: CS.CompileEnvironment):
  doc: ```
  Produces a new provides data structure that has no `dependency` NameOrigins
  in the types, by looking up dependencies in the compile environment.
  Also produces an error if there is a module URI or dependency that is not
  mentioned in the compile-env.
  ```
  transformer = lam(t :: T.Type%(is-t-name)):
    cases(T.Type) t:
    | t-name(origin, name, loc, inferred) =>
      cases(T.NameOrigin) origin:
      | local => T.t-name(T.module-uri(provides.from-uri), name, loc, inferred)
      | module-uri(uri) => t
      | dependency(d) =>
        provides-for-d = compile-env.provides-by-dep-key(d)
        cases(Option<CS.Provides>) provides-for-d:
        | some(p) => T.t-name(module-uri(p.from-uri), name, loc, inferred)
        | none => raise("Unknown module dependency for type: " + torepr(t) + " in provides for " + provides.from-uri)
        end
      end
    end
  end
  transform-provides(provides, compile-env, transformer)
end

fun localize-provides(provides :: CS.Provides, compile-env :: CS.CompileEnvironment):
  doc: ```
  Produces a new provides data structure that has no `module-uri` NameOrigins
  in the types, by looking up uris in the compile environment, or using `local`.

  Also produces an error if there is a module URI or dependency that is not
  mentioned in the compile-env.
  ```
  transformer = lam(t :: T.Type%(is-t-name)):
    cases(T.Type) t:
    | t-name(origin, name, loc, inferred) =>
      cases(T.NameOrigin) origin:
      | local => t
      | module-uri(uri) =>
        if uri == provides.from-uri:
          T.t-name(T.local, name, loc, inferred)
        else:
          t
        end
      | dependency(d) =>
        provides-for-d = compile-env.my-modules.get(d)
        cases(Option<CS.Provides>) provides-for-d:
        | some(p) => t
        | none => raise("Unknown module dependency for type: " + torepr(t) + " in provides for " + provides.from-uri)
        end
      end
    end
  end
  transform-provides(provides, compile-env, transformer)
end

# TODO(MATT): this does not actually get the provided module values
fun get-typed-provides(resolved, typed :: TCS.Typed, uri :: URI, compile-env :: CS.CompileEnvironment):
  transformer = lam(t):
    cases(T.Type) t:
      | t-name(origin, name, l, inferred) =>
        T.t-name(origin, A.s-type-global(name.toname()), l, inferred)
      | else => t
    end
  end
  c = canonicalize-names(_, uri, transformer)
  cases(A.Program) typed.ast block:
    | s-program(_, _, _, provide-blocks, _, _) =>
      cases(A.ProvideBlock) provide-blocks.first block:
        | s-provide-block(_, _, provide-specs) =>

          mp-specs = provide-specs.filter(A.is-s-provide-module)
          mod-provides = for fold(mp from [SD.string-dict:], m from mp-specs):
            cases(A.NameSpec) m.name-spec:
              | s-remote-ref(l, shadow uri, name, as-name) =>
                mod-info = compile-env.provides-by-uri-value(uri)
                mod-uri = mod-info.modules.get-value(name.toname())
                mp.set(as-name.toname(), mod-uri)
              | s-local-ref(l, name, as-name) =>
                mb = resolved.env.module-bindings.get-value-now(name.key())
                mp.set(as-name.toname(), mb.uri)
              | else => raise("All provides should be resolved to local or remote refs")
            end
          end
          
          vp-specs = provide-specs.filter(A.is-s-provide-name)
          val-provides = for fold(vp from [SD.string-dict:], v from vp-specs):
            cases(A.NameSpec) v.name-spec:
              | s-remote-ref(l, shadow uri, name, as-name) =>
                { origin-name; val-export } = compile-env.resolve-value-by-uri-value(uri, name.toname())
                vp.set(as-name.toname(), CS.v-alias(val-export.origin, origin-name))
              | s-local-ref(l, name, as-name) =>
                tc-typ = typed.info.types.get-value(name.key())
                val-bind = resolved.env.bindings.get-value-now(name.key())
                # TODO(joe): Still have v-var questions here
                vp.set(as-name.toname(), CS.v-just-type(val-bind.origin, c(tc-typ)))
            end
          end

          tp-specs = provide-specs.filter(A.is-s-provide-type)
          typ-provides = for fold(tp from [SD.string-dict:], t from tp-specs):
            cases(A.NameSpec) t.name-spec:
              | s-remote-ref(l, shadow uri, name, as-name) =>
                tp.set(as-name.toname(), T.t-name(T.module-uri(uri), name, l, false))
              | s-local-ref(l, name, as-name) =>
                key = name.key()
                cases(Option) typed.info.data-types.get(key):
                  | some(typ) => tp.set(name, c(typ))
                  | none =>
                    typ = typed.info.aliases.get-value(key)
                    tp.set(as-name.toname(), c(typ))
                end
            end

          end
          
          dp-specs = provide-specs.filter(A.is-s-provide-data)
          data-provides = for fold(dp from [SD.string-dict:], d from dp-specs):
            cases(A.NameSpec) d.name-spec:
              | s-remote-ref(l, shadow uri, name, as-name) =>
                # TODO(joe): Get better location information for SL.builtin(uri)
                dp.set(as-name.toname(), CS.d-alias(CS.bind-origin(l, SL.builtin(uri), false, uri, name), name.toname()))
              | s-local-ref(l, name, as-name) =>
                exp = resolved.env.datatypes.get-value-now(name.toname())
                origin = CS.bind-origin(l, exp.l, true, uri, name)
                dp.set(as-name.toname(), CS.d-type(origin, canonicalize-data-type(typed.info.data-types.get-value(exp.namet.key()), uri, transformer)))
                
            end
          end
          provs = CS.provides(
              uri,
              mod-provides,
              val-provides,
              typ-provides,
              data-provides)
          provs
      end
  end
end
