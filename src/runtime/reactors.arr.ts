const reactorEvents = require("./reactor-events.arr.js");
const tables = require("./tables.arr.js");;
const reactorLib = undefined;

// TODO(alex): Worry about value skeleton later
const VSlib = undefined;

const $ReactorBrand = {"names":false};

const isEvent = reactorEvents["is-Event"];

const DEFAULT_TICK = (1 / 28); // IN SECONDS
const DEFAULT_CLOSE = false;
const DEFAULT_TITLE = "reactor";

var externalInteractionHandler = null;
function setInteract(newInteract) {
  externalInteractionHandler = newInteract;
}

// TODO(alex): parameterize Reactor over init?
export interface Reactor {
  state: { currentValue: any, [key: string]: any },
  title: string,
  "seconds-per-tick": number,
  "close-when-stop": boolean,

  "get-value": () => any,
  "draw": () => any,
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

  var stateObject = {
    currentValue: init,
  };
  return {
    state: stateObject,
    title: DEFAULT_TITLE,
    "seconds-per-tick": DEFAULT_TICK,
    "close-when-stop": DEFAULT_CLOSE,

    "get-value": function() {
      return stateObject.currentValue;
    },

    "draw": function() {
      if (handlers["to-draw"] === undefined) {
        throw "Cannot draw() because no to-draw was specified on this reactor";
      }

      let drawer = handlers["to-draw"];
      return drawer(init);
    },

  };
}
