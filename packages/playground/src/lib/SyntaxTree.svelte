<script lang="ts">
  import type { TreeRow } from "tql";

  type Row = TreeRow & { isError: boolean };

  let { tree, onSelect }: { tree: TreeRow[]; onSelect: (start: number, end: number) => void } =
    $props();

  let showAnonymous = $state(false);

  const rows = $derived.by<Row[]>(() =>
    tree
      .filter((r) => showAnonymous || r.isNamed)
      .map((r) => ({ ...r, isError: r.type === "ERROR" })),
  );
</script>

<label class="toggle">
  <input type="checkbox" bind:checked={showAnonymous} />
  Show anonymous nodes
</label>
<div class="tree">
  {#each rows as row}
    <button
      type="button"
      class="row"
      class:named={row.isNamed && !row.isError}
      class:anonymous={!row.isNamed}
      class:error={row.isError || row.isMissing}
      style="padding-left: {row.depth * 12}px"
      onclick={() => onSelect(row.startIndex, row.endIndex)}
    >
      {#if row.fieldName}<span class="field">{row.fieldName}:</span> {/if}<span class="type"
        >{row.isNamed ? row.type : `"${row.type}"`}</span
      >
      <span class="position">[{row.startRow}, {row.startCol}] - [{row.endRow}, {row.endCol}]</span>
    </button>
  {/each}
</div>

<style>
  .tree {
    font-family: ui-monospace, monospace;
    font-size: 13px;
    max-height: 400px;
    overflow: auto;
    border: 1px solid #ddd;
    padding: 4px 0;
  }
  .row {
    display: block;
    width: 100%;
    text-align: left;
    border: none;
    background: transparent;
    padding: 1px 8px;
    font: inherit;
    cursor: pointer;
    white-space: nowrap;
  }
  .row:hover {
    background: #eef3ff;
  }
  .named {
    color: #1976d2;
  }
  .anonymous {
    color: #6a737d;
  }
  .error {
    color: #d32f2f;
  }
  .field {
    font-style: italic;
    color: #6a737d;
  }
  .position {
    color: #999;
    font-size: 11px;
    margin-left: 6px;
  }
  .toggle {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 13px;
    margin-bottom: 4px;
  }
</style>
