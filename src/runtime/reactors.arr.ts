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

function makeReactorRaw(init: any, handlers: object, 
                        tracing: boolean, trace: any[]): Reactor {
  return {
    init: init,

    "get-value": function() {
      return init;
    }
  };
}
