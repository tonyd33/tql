<script lang="ts">
  let { engine } = $props();

  let query = $state(`with @root > function_definition.declarator as @func_decl,
     @func_decl.parameters > parameter_declaration as @param_decl,
     @func_decl.declarator as @func_name
select { name: @func_name, parameter: @param_decl }
`);
  let target = $state(`int add(int a, int b) { return a + b; }
int main(void) { return add(1, 2); }
`);

  let selectedLanguage = $state(0);
  const languages = [
    { name: 'C++', value: 0, },
    { name: 'C', value: 1, },
    { name: 'Go', value: 2, },
    { name: 'JavaScript', value: 3, },
    { name: 'Python', value: 4, },
    { name: 'Rust', value: 5, },
    { name: 'TSX', value: 6, },
    { name: 'TypeScript', value: 7, },
    { name: 'Zig', value: 8, },
  ];

  let result = $state(null);
  function run() {
    result = engine.query({
      querySource: query,
      queryTarget: target,
      language: selectedLanguage,
    });
  }
</script>

<form id="controls">
  <label for="language">Language</label>
  <select bind:value={selectedLanguage}>
    {#each languages as language}
    <option value={language.value}>{language.name}</option>
    {/each}
  </select>
  <button id="run" type="button" onclick={run}>Run</button>
</form>
<section id="editors">
  <fieldset>
    <legend>Query</legend>
    <textarea id="query-source" rows="16" spellcheck="false" bind:value={query}></textarea>
  </fieldset>
  <fieldset>
    <legend>Target</legend>
    <textarea id="query-target" rows="16" spellcheck="false" bind:value={target}></textarea>
  </fieldset>
</section>
<section id="results">
  <h2>Output</h2>
  <output id="stats"></output>
  <pre>{JSON.stringify(result, null, 2)}</pre>
</section>

<style>
  #editors {
    display: flex;
    gap: 8px;
  }

  textarea {
    font-family: ui-monospace, monospace;
    font-size: 16px;
  }
  #editors fieldset {
    flex: 1;
  }

  #editors textarea {
    width: 100%;
    font-size: 18px;
  }
</style>
