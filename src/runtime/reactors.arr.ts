const reactorEvents = require("./reactor-events.arr.js");
const tables = require("./tables.arr.js");;
const reactorLib = undefined;

// TODO(alex): Worry about value skeleton later
const VSlib = undefined;

const $ReactorBrand = {"names":false};

const isEvent = reactorEvents["is-Event"];

var externalInteractionHandler = null;

// TODO(alex): parameterize Reactor over init?
export interface Reactor {
  init: any,
  "get-value": () => any,
  "draw": () => any,
}

export interface Handlers {
  "on-tick"?: (init: any) => any,
  "on-mouse"?: (current: any, x: number, y: number, kind: string) => any,
  "on-key"?: (current: any, key: string) => any,
  "stop-when"?: (current: any) => boolean,
  "to-draw"?: (init: any) => any,
}

function setInteract(newInteract) {
  externalInteractionHandler = newInteract;
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
    init: init,

    "get-value": function() {
      return init;
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
