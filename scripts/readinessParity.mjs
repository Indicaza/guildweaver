// Writes the addon's readiness parity fixture from Holdfast's own engine.
//   node scripts/readinessParity.mjs <holdfast backend dir> test/fixtures/readiness-parity.json
import { writeFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [backend, out] = process.argv.slice(2);
const { atlasReadiness } = await import(pathToFileURL(path.join(backend, "src/Atlas/atlasRepository.js")).href);
const commit = execSync("git rev-parse HEAD", { cwd: backend }).toString().trim();

const base = { schemaVersion: 1, faction: "alliance", race: "Human", classToken: "WARRIOR", level: 20,
  completed: { coverage: "full", questIds: [] }, questLog: { coverage: "full", questIds: [] } };
const states = {
  nothing: { schemaVersion: 1, completed: { coverage: "none" }, questLog: { coverage: "none" } },
  freshAlliance: base,
  defiasDone: { ...base, completed: { coverage: "full", questIds: [65, 132, 135, 141, 142, 155, 166, 214, 167] }, questLog: { coverage: "full", questIds: [168, 2040] } },
  checkedOnly: { ...base, completed: { coverage: "checked", questIds: [155, 166], checkedQuestIds: [155, 166, 214, 167] }, questLog: { coverage: "full", questIds: [168] } },
  logUnread: { ...base, completed: { coverage: "full", questIds: [155] }, questLog: { coverage: "none" } },
  hordeOrc: { ...base, faction: "horde", race: "Orc", classToken: "SHAMAN", level: 58 },
  allianceMage58: { ...base, classToken: "MAGE", race: "Gnome", level: 58, completed: { coverage: "full", questIds: [5001, 5089, 4766, 4742, 4769] } },
  unknownWho: { ...base, faction: null, race: null, classToken: null, level: null },
  lowLevel: { ...base, level: 5 },
};
const guides = [36, 229, "blackrock-spire:lower", "blackrock-spire:upper", 3065, 2974, 389, 429, 209, 189, "scarlet-monastery:library", 1, 249];

const pick = (rows) => rows.map((row) => [row.questId, row.state, row.reasons]);
const cases = [];
for (const guide of guides) {
  for (const [stateName, state] of Object.entries(states)) {
    const outcome = atlasReadiness(String(guide), state);
    if (!outcome) { cases.push({ guide, state: stateName, missing: true }); continue; }
    const r = outcome.result;
    cases.push({ guide, state: stateName, readiness: r.readiness, required: r.required, counts: r.counts,
      quests: pick(r.quests), optional: pick(r.optional), prerequisites: pick(r.prerequisites), repeatable: pick(r.repeatable), unknownRelevance: pick(r.unknownRelevance) });
  }
}
writeFileSync(out, JSON.stringify({ generatedBy: "Holdfast backend/src/Atlas/atlasReadiness.js", commit, states, cases }));
console.log(`${cases.length} cases, ${cases.filter((c) => c.missing).length} without a catalog entry`);
