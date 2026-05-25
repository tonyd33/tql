import { init, Language, type Engine } from "tql";

const $ = <T extends HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`missing #${id}`);
  return el as T;
};

const querySourceEl = $<HTMLTextAreaElement>("query-source");
const queryTargetEl = $<HTMLTextAreaElement>("query-target");
const languageEl = $<HTMLSelectElement>("language");
const runEl = $<HTMLButtonElement>("run");
const outputEl = $<HTMLPreElement>("output");
const statsEl = $<HTMLDivElement>("stats");

let engine: Engine | null = null;

async function boot() {
  runEl.disabled = true;
  outputEl.textContent = "loading wasm...";
  try {
    engine = await init({
      compilation: { via: "streaming", source: fetch("./tql.wasm") },
    });
    outputEl.textContent = "ready";
    runEl.disabled = false;
  } catch (e) {
    outputEl.textContent = `init failed: ${(e as Error).message}`;
  }
}

function run() {
  if (!engine) return;
  const lang =
    Language[languageEl.value as keyof typeof Language] ?? Language.c;
  const t0 = performance.now();
  try {
    const result = engine.query({
      querySource: querySourceEl.value,
      queryTarget: queryTargetEl.value,
      language: lang,
    });
    const wall = (performance.now() - t0).toFixed(2);
    outputEl.textContent = JSON.stringify(result.values, null, 2);
    statsEl.textContent = `wall ${wall}ms * parse ${result.stats.parse_time_ns}ns * query ${result.stats.query_time_ns}ns`;
  } catch (e) {
    outputEl.textContent = `error: ${(e as Error).message}`;
    statsEl.textContent = "";
  }
}

runEl.addEventListener("click", run);

void boot();
