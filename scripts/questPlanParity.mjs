// Writes the add-on's quest plan parity fixture from Holdfast's own planner
// (backend/src/Atlas/atlasQuestPlan.js), as readinessParity.mjs does for readiness.
//   node scripts/questPlanParity.mjs <holdfast backend dir> test/fixtures/quest-plan-parity.json
// Each case keeps what the add-on must reproduce: every step's id, kind,
// quest, status and waypoint in order (text is the client's own), the
// waypoints (UiMap id, permille x/y, target type), next and readiness.
// Editorial cases: SYNTHETIC published quest edits (contract schema 1, made
// up for tests, not game facts), passed through Holdfast's own export
// normalization (exportableEditorialQuestPlan) exactly as the add-on
// packages them; the add-on's spec feeds the same documents to its planner.
import { writeFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [backend, out] = process.argv.slice(2);
const { atlasQuestPlanFromState } = await import(pathToFileURL(path.join(backend, "src/Atlas/atlasQuestPlanRepository.js")).href);
const { exportableEditorialQuestPlan } = await import(pathToFileURL(path.join(backend, "src/Atlas/atlasQuestPlan.js")).href);
const { loadAtlas } = await import(pathToFileURL(path.join(backend, "src/Atlas/atlasData.js")).href);
const commit = execSync("git rev-parse HEAD", { cwd: backend }).toString().trim();

const entries = (ids, complete = {}) => ids.map((questId) => (questId in complete ? { questId, isComplete: complete[questId] } : { questId }));
const base = { schemaVersion: 1, faction: "alliance", race: "Human", classToken: "WARRIOR", level: 20,
  completed: { coverage: "full", questIds: [] }, questLog: { coverage: "full", entries: [] } };
const states = {
  nothing: { schemaVersion: 1, completed: { coverage: "none" }, questLog: { coverage: "none" } },
  freshAlliance: base,
  defiasHalfway: { ...base, completed: { coverage: "full", questIds: [65, 132, 135, 141] },
    questLog: { coverage: "full", entries: entries([142, 2040, 167, 168], { 142: false, 2040: true, 167: false }) } },
  defiasDone: { ...base, completed: { coverage: "full", questIds: [65, 132, 135, 141, 142, 155, 166, 214, 167] },
    questLog: { coverage: "full", entries: entries([168, 2040], { 168: true }) } },
  checkedOnly: { ...base, completed: { coverage: "checked", questIds: [155, 166], checkedQuestIds: [155, 166, 214, 167] },
    questLog: { coverage: "full", entries: entries([168]) } },
  logUnread: { ...base, completed: { coverage: "full", questIds: [155] }, questLog: { coverage: "none" } },
  hordeOrc: { ...base, faction: "horde", race: "Orc", classToken: "SHAMAN", level: 58 },
  dwarf42: { ...base, race: "Dwarf", classToken: "PALADIN", level: 42, completed: { coverage: "full", questIds: [707, 720] },
    questLog: { coverage: "full", entries: entries([2198, 721], { 2198: true }) } },
  allianceMage58: { ...base, classToken: "MAGE", race: "Gnome", level: 58, completed: { coverage: "full", questIds: [5001, 5089, 4766, 4742, 4769] } },
  unknownWho: { ...base, faction: null, race: null, classToken: null, level: null },
};
const guides = [36, 70, 230, 229, "blackrock-spire:lower", "blackrock-spire:upper", 3065, 2974, 209, 189, "scarlet-monastery:library", 1];

// SYNTHETIC editorial documents (ids and NPC names are the catalog's; every
// edit, location, step and instruction is made up for the parity test).
const SYNTHETIC = "synthetic parity fixture";
const rawEditorials = {
  deadmines: { schemaVersion: 1, instanceId: 36, revision: "parity-1",
    entrance: { mapId: 1436, x: 0.4205, y: 0.7183, zoneName: "Westfall", verified: true, source: SYNTHETIC },
    instructions: [{ section: "enter", text: "Synthetic: gather at the entrance.", verified: false, source: SYNTHETIC },
      { section: "collect", text: "Synthetic: start in Westfall.", verified: false, source: SYNTHETIC }],
    quests: [
      { questId: 214, shareable: "no", verified: false, source: SYNTHETIC },
      { questId: 168, shareable: "yes", giver: { name: "Synthetic giver", location: { mapId: 1436, x: 0.5, y: 0.5, zoneName: "Westfall" } },
        steps: [{ text: "Synthetic step one." }, { text: "Synthetic step two." }], verified: true, source: SYNTHETIC },
      { questId: 166, turnIn: { name: "Gryan Stoutmantle", location: { mapId: 1436, x: 0.5633, y: 0.4752, zoneName: "Westfall" } }, verified: false, source: SYNTHETIC },
      { questId: 167, prerequisites: [-168], verified: false, source: SYNTHETIC },
      { questId: 2040, turnIn: { name: "Synthetic turn-in" }, verified: false, source: SYNTHETIC },
      { questId: 424242, shareable: "yes", verified: false, source: SYNTHETIC },
    ] },
  hall: { schemaVersion: 1, instanceId: 3065, revision: "parity-2",
    quests: [
      { questId: 96394, prerequisites: [96393], verified: false, source: SYNTHETIC },
      { questId: 96393, giver: { name: "Synthetic Thane", location: { mapId: 1455, x: 0.3, y: 0.4, zoneName: "Ironforge" } }, verified: false, source: SYNTHETIC },
      { questId: 98423, shareable: "yes", relevance: "optional", verified: false, source: SYNTHETIC },
    ] },
  uldaman: { schemaVersion: 1, instanceId: 70, revision: null,
    quests: [
      { questId: 2198, turnIn: { name: "Synthetic turn-in", location: { mapId: 1418, x: 0.1, y: 0.2, zoneName: "Badlands" } }, verified: true, source: SYNTHETIC },
      { questId: 721, shareable: "no", steps: [{ text: "Synthetic step." }], verified: false, source: SYNTHETIC },
    ] },
};
const editorials = Object.fromEntries(Object.entries(rawEditorials).map(([name, raw]) => {
  const { document, problems } = exportableEditorialQuestPlan(raw, raw.instanceId);
  if (problems.length) throw new Error(`${name}: ${JSON.stringify(problems)}`);
  return [name, document];
}));
const editorialCases = [["deadmines", 36], ["hall", 3065], ["uldaman", 70]];
const editorialStates = ["nothing", "freshAlliance", "defiasHalfway", "defiasDone", "dwarf42", "hordeOrc"];

const flatten = (steps, depth, rows) => {
  for (const step of steps) {
    rows.push([step.id, step.kind, step.questId, step.status, step.waypoint, depth]);
    flatten(step.children, depth + 1, rows);
  }
  return rows;
};
const cases = [];
for (const guide of guides) {
  for (const [stateName, state] of Object.entries(states)) {
    const outcome = atlasQuestPlanFromState(String(guide), { state });
    if (!outcome) { cases.push({ guide, state: stateName, missing: true }); continue; }
    if (outcome.status !== "ok") throw new Error(`${guide}/${stateName}: ${outcome.problems.join("; ")}`);
    const plan = outcome.result;
    const entrance = plan.waypoints.find((waypoint) => waypoint.id === "wp:entrance");
    cases.push({
      guide, state: stateName,
      entrance: entrance ? { mapId: entrance.mapId, x: Math.round(entrance.x * 1000), y: Math.round(entrance.y * 1000), zoneName: entrance.zoneName } : null,
      readiness: plan.readiness.readiness, next: plan.next,
      sections: Object.fromEntries(plan.sections.map((section) => [section.key, flatten(section.steps, 0, [])])),
      waypoints: plan.waypoints.map((waypoint) => [waypoint.id, waypoint.mapId, Math.round(waypoint.x * 1000), Math.round(waypoint.y * 1000), waypoint.targetType]),
      problems: plan.problems.map((problem) => problem.code),
    });
  }
}
const atlas = loadAtlas();
for (const [name, instanceId] of editorialCases) {
  const dungeon = atlas.byId.get(instanceId);
  const atlasEntrance = dungeon?.entrance ? { mapId: dungeon.entrance.mapId, x: Math.round(dungeon.entrance.x * 1000), y: Math.round(dungeon.entrance.y * 1000),
    zoneName: dungeon.zoneName ?? null } : null;
  for (const stateName of editorialStates) {
    const outcome = atlasQuestPlanFromState(String(instanceId), { state: states[stateName], editorial: editorials[name] });
    if (outcome.status !== "ok") throw new Error(`${name}/${stateName}: ${outcome.problems.join("; ")}`);
    const plan = outcome.result;
    cases.push({
      guide: instanceId, state: stateName, editorial: name, entrance: atlasEntrance,
      readiness: plan.readiness.readiness, next: plan.next, used: plan.editorial.used,
      sections: Object.fromEntries(plan.sections.map((section) => [section.key, flatten(section.steps, 0, [])])),
      notes: Object.fromEntries(plan.sections.map((section) => [section.key, section.notes.length])),
      waypoints: plan.waypoints.map((waypoint) => [waypoint.id, waypoint.mapId, Math.round(waypoint.x * 1000), Math.round(waypoint.y * 1000), waypoint.targetType,
        waypoint.source, waypoint.verified]),
      problems: plan.problems.map((problem) => problem.code),
    });
  }
}
writeFileSync(out, JSON.stringify({ generatedBy: "Holdfast backend/src/Atlas/atlasQuestPlan.js", commit, states, editorials, cases }));
console.log(`${cases.length} cases (${cases.filter((entry) => entry.editorial).length} with editorial edits), ${cases.filter((entry) => entry.missing).length} without a catalog entry`);
