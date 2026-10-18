<script lang="ts">
  import { EditorView } from "codemirror";
  import { EditorSelection } from "@codemirror/state";
  import { type Diagnostic as Lint } from "@codemirror/lint";
  import { type Diagnostic, type MessagePart, type QueryResult, type TreeRow, type Grammar } from "tql";
  import { engine, loadLanguage, availableGrammars } from "$lib/boot";
  import SyntaxTree from "$lib/SyntaxTree.svelte";
  import Editor from "$lib/Editor.svelte";
  import { utf16Index } from "$lib/utf8";

  let query = $state(`int_type = #type | arr text | keep (\\t -> t == "int");

int_params =
  #declarator
  | #parameters
  | children_of_kind :parameter_declaration
  | keep (has int_type)
  | #declarator
  | arr text;

main = do {
  f <- descendants_of_kind :function_definition;
  name <- pure f | #declarator | #declarator;
  return { func = text name, int_params = run int_params f };
};`);
  let target = $state(`#include <stddef.h>
#include <stdio.h>

int add(int a, int b) {
  return a + b;
}

size_t strlen(const char *s) {
  const char *p = s;
  while (*p++) {}
  return p - s;
}

int main(int argc, char **argv) {
  printf("Hello world\\n");
  printf("strlen(\\"Hello world\\") = %lu\\n", strlen("Hello world"));
  printf("add(1, 2) = %d\\n", add(1, 2));
  return 0;
}`);

  let grammarKey = $state("c");

  let targetView: EditorView | undefined;
  function highlightTarget(start: number, end: number) {
    if (!targetView) return;
    targetView.focus();
    targetView.dispatch({
      selection: EditorSelection.single(utf16Index(target, start), utf16Index(target, end)),
      scrollIntoView: true,
    });
  }

  let loaded = $state<Grammar | null>(null);
  $effect(() => {
    const key = grammarKey;
    loadLanguage(key).then((g) => {
      if (grammarKey !== key) return;
      loaded = g;
    });
  });

  const tree = $derived.by<TreeRow[] | null>(() => {
    if (!loaded) return null;
    const outcome = engine.parseTree(loaded, target);
    return outcome.kind === "ok" ? outcome.rows : null;
  });

  let result = $state<QueryResult | null>(null);
  let error = $state<MessagePart[][] | null>(null);
  let lints = $state<Lint[]>([]);
  function run() {
    if (!loaded) return;
    const outcome = engine.query({
      querySource: query,
      queryTarget: target,
      grammar: loaded,
    });
    switch (outcome.kind) {
      case "ok":
        result = outcome.result;
        error = null;
        lints = [];
        break;
      case "rejected":
        result = null;
        error = outcome.diagnostics.map(describe);
        lints = outcome.diagnostics.flatMap(lint);
        break;
      case "failed":
        result = outcome.result ?? null;
        error = [[{ text: `error[${outcome.failure.category}]: ${outcome.failure.message}` }]];
        lints = [];
        break;
    }
  }

  function describe(d: Diagnostic): MessagePart[] {
    const header = `error[${d.category}]: `;
    const at = d.span === null ? "" : `${d.span.start_point.row + 1}:${d.span.start_point.column + 1}: `;
    const prefix = d.module === null || d.span === null ? at : `${d.module}:${at}`;
    return [{ text: prefix + header }, ...d.parts];
  }

  function lint(d: Diagnostic): Lint[] {
    if (d.module !== null || d.span === null) return [];
    const from = utf16Index(query, d.span.start_byte);
    const to = utf16Index(query, d.span.end_byte);
    return [{ from, to, severity: "error", source: d.category, message: d.message }];
  }
</script>

<div class="app">
  <aside class="sidebar">
    <h1>tql</h1>
    <label class="field">
      <span>Grammar</span>
      <select bind:value={grammarKey}>
        {#each availableGrammars as grammar}
          <option value={grammar.key}>{grammar.displayName}</option>
        {/each}
      </select>
    </label>
    <button class="run" type="button" onclick={run}>Run</button>
  </aside>

  <section class="panel panel-query">
    <header>Query</header>
    <div class="panel-body"><Editor bind:value={query} diagnostics={lints} /></div>
  </section>

  <section class="panel panel-target">
    <header>Target</header>
    <div class="panel-body">
      <Editor bind:value={target} lang={grammarKey} onReady={(v) => (targetView = v)} />
    </div>
  </section>

  <section class="panel panel-tree">
    <header>Syntax Tree</header>
    <div class="panel-body">
      {#if tree}
        <SyntaxTree {tree} onSelect={highlightTarget} />
      {/if}
    </div>
  </section>

  <section class="panel panel-output">
    <header>Output</header>
    <div class="panel-body">
      {#if result}
        <pre>{JSON.stringify(result, null, 2)}</pre>
      {/if}
      {#if error}
        <pre class="error">{#each error as line}{#each line as part}{#if "code" in part}`<code>{part.code}</code>`{:else}{part.text}{/if}{/each}{"\n"}{/each}</pre>
      {/if}
    </div>
  </section>
</div>

<style>
  :global(html, body) {
    margin: 0;
    height: 100%;
    background: #fafafa;
    color: #1a1a1a;
    font-family: system-ui, sans-serif;
  }
  :global(body > div) {
    height: 100%;
  }

  .app {
    height: 100vh;
    display: grid;
    grid-template-columns: 200px 1fr 1fr;
    grid-template-rows: 1fr 1fr;
    grid-template-areas:
      "sidebar query target"
      "sidebar tree   output";
    gap: 8px;
    padding: 8px;
    box-sizing: border-box;
  }

  .sidebar {
    grid-area: sidebar;
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 12px;
    background: #fff;
    border: 1px solid #e0e0e0;
    border-radius: 6px;
  }
  .sidebar h1 {
    margin: 0;
    font-size: 18px;
    letter-spacing: 0.05em;
  }
  .field {
    display: flex;
    flex-direction: column;
    gap: 4px;
    font-size: 13px;
  }
  .field select {
    padding: 4px 6px;
    font: inherit;
  }
  .run {
    padding: 8px;
    font: inherit;
    background: #1976d2;
    color: #fff;
    border: none;
    border-radius: 4px;
    cursor: pointer;
  }
  .run:hover {
    background: #1565c0;
  }

  .panel {
    display: flex;
    flex-direction: column;
    background: #fff;
    border: 1px solid #e0e0e0;
    border-radius: 6px;
    min-height: 0;
    overflow: hidden;
  }
  .panel-query {
    grid-area: query;
  }
  .panel-target {
    grid-area: target;
  }
  .panel-tree {
    grid-area: tree;
  }
  .panel-output {
    grid-area: output;
  }
  .panel header {
    padding: 6px 12px;
    font-size: 12px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: #555;
    border-bottom: 1px solid #e0e0e0;
    background: #f5f5f5;
  }
  .panel-body {
    flex: 1;
    min-height: 0;
    overflow: auto;
  }
  .panel-body pre {
    margin: 0;
    padding: 8px;
    font-family: ui-monospace, monospace;
    font-size: 13px;
  }
  .panel-body pre.error {
    color: #c62828;
    white-space: pre-wrap;
  }
  .panel-body pre.error code {
    font-weight: 600;
    color: #1a1a1a;
  }
  .panel-body :global(.editor) {
    height: 100%;
    border: none;
  }
  .panel-body :global(.tree) {
    max-height: none;
    border: none;
  }

  @media (max-width: 900px) {
    .app {
      height: auto;
      min-height: 100vh;
      grid-template-columns: 1fr;
      grid-template-rows: auto;
      grid-template-areas:
        "sidebar"
        "query"
        "target"
        "tree"
        "output";
    }
    .sidebar {
      flex-direction: row;
      align-items: end;
      flex-wrap: wrap;
    }
    .panel {
      min-height: 320px;
    }
  }
</style>
