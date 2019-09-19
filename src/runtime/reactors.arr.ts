const reactorEvents = require("./reactor-events.arr.js");
const tables = require("./tables.arr.js");;
const reactorLib = undefined;

// TODO(alex): Worry about value skeleton later
const VSlib = undefined;

const $ReactorBrand = {"names":false};

const isEvent = reactorEvents["is-Event"];

var externalInteractionHandler = null;

function setInteract(newInteract) {
  externalInteractionHandler = newInteract;
}
