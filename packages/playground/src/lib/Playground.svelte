<script lang="ts">
  import { Parser, type Tree } from "web-tree-sitter";
  import { EditorView } from "codemirror";
  import { EditorSelection } from "@codemirror/state";
  import { languages, Language, type QueryResult } from "tql";
  import { engine, loadLanguage } from "$lib/boot";
  import SyntaxTree from "$lib/SyntaxTree.svelte";
  import Editor from "$lib/Editor.svelte";
  const parser = new Parser();

  let query = $state(`with @root > function_definition.declarator as @func_decl,
     @func_decl.declarator as @func_name,
     (
       with @func_decl.parameters > parameter_declaration as @param,
            @param.type as @param_type,
            @param.declarator as @param_name
       where @param_type = 'int'
       select @param_name
     ) as @int_param_names
select { @func_name, @int_param_names }`);
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

  let selectedLanguage = $state<Language>(Language.c);
  const langKey = $derived(languages.find((l) => l.id === selectedLanguage)!.key);

  let targetView: EditorView | undefined;
  function highlightTarget(start: number, end: number) {
    if (!targetView) return;
    targetView.focus();
    targetView.dispatch({
      selection: EditorSelection.single(start, end),
      scrollIntoView: true,
    });
  }

  let tree = $state<Tree | null>(null);
  $effect(() => {
    const key = langKey;
    loadLanguage(key).then((lang) => {
      if (langKey !== key) return;
      parser.setLanguage(lang);
      tree = parser.parse(target);
    });
  });
  $effect(() => {
    if (parser.language) tree = parser.parse(target);
  });

  let result = $state<QueryResult | null>(null);
  function run() {
    result = engine.query({
      querySource: query,
      queryTarget: target,
      language: selectedLanguage,
    });
  }
</script>

<div class="app">
  <aside class="sidebar">
    <h1>tql</h1>
    <label class="field">
      <span>Language</span>
      <select bind:value={selectedLanguage}>
        {#each languages as language}
          <option value={language.id}>{language.displayName}</option>
        {/each}
      </select>
    </label>
    <button class="run" type="button" onclick={run}>Run</button>
  </aside>

  <section class="panel panel-query">
    <header>Query</header>
    <div class="panel-body"><Editor bind:value={query} /></div>
  </section>

  <section class="panel panel-target">
    <header>Target</header>
    <div class="panel-body">
      <Editor bind:value={target} lang={langKey} onReady={(v) => (targetView = v)} />
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
      <pre>{result ? JSON.stringify(result, null, 2) : ""}</pre>
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
