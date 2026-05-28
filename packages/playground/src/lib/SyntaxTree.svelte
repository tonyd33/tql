<script lang="ts">
  import type { Tree } from "web-tree-sitter";

  type Row = {
    depth: number;
    fieldName: string | null;
    type: string;
    isNamed: boolean;
    isError: boolean;
    isMissing: boolean;
    startIndex: number;
    endIndex: number;
    startRow: number;
    startCol: number;
    endRow: number;
    endCol: number;
  };

  let { tree, onSelect }: { tree: Tree; onSelect: (start: number, end: number) => void } = $props();

  let showAnonymous = $state(false);

  const rows = $derived.by<Row[]>(() => {
    const out: Row[] = [];
    const cursor = tree.walk();
    let depth = 0;
    const visit = () => {
      if (showAnonymous || cursor.nodeIsNamed) {
        out.push({
        depth,
        fieldName: cursor.currentFieldName ?? null,
        type: cursor.nodeType,
        isNamed: cursor.nodeIsNamed,
        isError: cursor.nodeType === "ERROR",
        isMissing: cursor.nodeIsMissing,
        startIndex: cursor.startIndex,
        endIndex: cursor.endIndex,
        startRow: cursor.startPosition.row,
        startCol: cursor.startPosition.column,
        endRow: cursor.endPosition.row,
        endCol: cursor.endPosition.column,
        });
      }
      if (cursor.gotoFirstChild()) {
        depth++;
        do {
          visit();
        } while (cursor.gotoNextSibling());
        cursor.gotoParent();
        depth--;
      }
    };
    visit();
    cursor.delete();
    return out;
  });
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
