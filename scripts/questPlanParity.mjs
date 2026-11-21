// Writes the add-on's quest plan parity fixture from Holdfast's own planner
// (backend/src/Atlas/atlasQuestPlan.js), as readinessParity.mjs does for readiness.
//   node scripts/questPlanParity.mjs <holdfast backend dir> test/fixtures/quest-plan-parity.json
// Each case keeps what the add-on must reproduce: every step's id, kind,
// quest, status and waypoint in order (text is the client's own), the
// waypoints (UiMap id, permille x/y, target type), next and readiness.
// No editorial data: the add-on plans from the packaged catalog alone.
import { writeFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [backend, out] = process.argv.slice(2);
const { atlasQuestPlanFromState } = await import(pathToFileURL(path.join(backend, "src/Atlas/atlasQuestPlanRepository.js")).href);
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
writeFileSync(out, JSON.stringify({ generatedBy: "Holdfast backend/src/Atlas/atlasQuestPlan.js", commit, states, cases }));
console.log(`${cases.length} cases, ${cases.filter((entry) => entry.missing).length} without a catalog entry`);
