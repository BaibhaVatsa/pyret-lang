const RUNTIME = require("./runtime.js");
const REACTOR_EVENTS = require("./reactor-events.arr.js");
const TABLES = require("./tables.arr.js");;
const REACTOR_LIB = undefined;

// TODO(alex): Worry about value skeleton later
const VS_LIB = undefined;

const $ReactorBrand = {"names":false};

const isEvent = REACTOR_EVENTS["is-Event"];
const isKeypress = REACTOR_EVENTS["is-keypress"];
const isMouse = REACTOR_EVENTS["is-mouse"];
const isTimeTick = REACTOR_EVENTS["is-time-tick"];

const DEFAULT_TICK = (1 / 28); // IN SECONDS
const DEFAULT_CLOSE = false;
const DEFAULT_TITLE = "reactor";

var externalInteractionHandler = null;
function setInteract(newInteract) {
  externalInteractionHandler = newInteract;
}

// TODO(alex): parameterize Reactor over init?
export interface Reactor {
  title: string,
  "seconds-per-tick": number,
  "close-when-stop": boolean,

  "get-value": () => any,
  "draw": () => any,

  "react": (event: any) => any,
}

export interface Handlers {
  "on-tick"?: (current: any) => any,
  "on-mouse"?: (current: any, x: number, y: number, kind: string) => any,
  "on-key"?: (current: any, key: string) => any,
  "stop-when"?: (current: any) => boolean,
  "to-draw"?: (current: any) => any,
}

function makeReactor(init: any, fields: object): Reactor {
  let handlerDict = {};
  Object.keys(fields).forEach((f) => {
    handlerDict[f] = fields[f];
  });

  return makeReactorRaw(init, handlerDict, false, []);
}

function makeReactorRaw(init: any, handlers: Handlers, 
                        tracing: boolean, trace: any[]): Reactor {

  return {
    title: DEFAULT_TITLE,
    "seconds-per-tick": DEFAULT_TICK,
    "close-when-stop": DEFAULT_CLOSE,

    "get-value": function() {
      return init;
    },

    "draw": function() {
      if (handlers["to-draw"] === undefined) {
        throw "Cannot draw() because no to-draw was specified on this reactor";
      }

      // TODO(alex): call pauseStack?
      let drawer = handlers["to-draw"];
      return drawer(init);
    },

    // NO state changed
    // A NEW reactor is created
    react: function(event: object): any {
      function callOrError(handlerName: string, args: any[]) {
        if (handlers[handlerName] === undefined) {

          // Execute the handler
          let handler = handlers[handlerName];
          let result = handler.apply(args);
          let newTrace = null;
          if (tracing) {
            newTrace = trace.concat(result);
          } else {
            newTrace = trace;
          }

          let newReactor = makeReactorRaw(result, handlers, tracing, newTrace);
          return newReactor;

        } else {
          // No handler
          throw new Error(`No ${handlerName} handler defined`);
        }
      }

      // Main dispatcher
      return RUNTIME.pauseStack(function(restarter) {
        let stop = false;
        if (handlers["stop-when"]) {
          stop = handlers["stop-when"](init);
        }

        if (stop) {
          restarter.resume(init);
        } else {
          if (isKeypress(event)) {

            let keyEvent = event;
            let key = keyEvent["key"];
            restarter.resume(callOrError("on-key", [init, key]));

          } else if (isTimeTick(event)) {

            let tickEvent = event;
            restarter.resume(callOrError("on-tick", [init]));

          } else if (isMouse(event)) {
            let mouseEvent = event;
            let x = mouseEvent["x"];
            let y = mouseEvent["y"];
            let kind = mouseEvent["kind"];
            restarter.resume(
              callOrError("on-mouse", [init, x, y, kind]));
          } else {
            restarter.error(new Error("Unknown event: " + event));
          }
        }

      });
    },

    "is-stopped": function() {
      if (handlers["stop-when"]) {
        return handlers["stop-when"](init);

        // TODO(alex): Call pauseStack?
          /*
        return RUNTIME.pauseStack(function(restarter) {
          restarter.resume(handlers["stop-when"](stateObject.currentValue));
        });
           */
      } else {
        return false;
      }
    }

  };
}
