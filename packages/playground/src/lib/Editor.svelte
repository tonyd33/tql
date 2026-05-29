<script lang="ts">
  import { onMount } from "svelte";
  import { EditorView, basicSetup } from "codemirror";
  import { EditorState, Compartment } from "@codemirror/state";
  import { javascript } from "@codemirror/lang-javascript";
  import { cpp } from "@codemirror/lang-cpp";
  import { go } from "@codemirror/lang-go";
  import { python } from "@codemirror/lang-python";
  import { rust } from "@codemirror/lang-rust";

  type Lang = "cpp" | "c" | "go" | "javascript" | "python" | "rust" | "tsx" | "typescript" | "zig";

  let {
    value = $bindable(""),
    lang,
    onReady,
  }: {
    value: string;
    lang?: Lang;
    onReady?: (view: EditorView) => void;
  } = $props();

  function extFor(l: Lang | undefined) {
    if (!l) return [];
    switch (l) {
      case "cpp":
      case "c":
        return cpp();
      case "go":
        return go();
      case "python":
        return python();
      case "rust":
        return rust();
      case "javascript":
        return javascript();
      case "typescript":
        return javascript({ typescript: true });
      case "tsx":
        return javascript({ typescript: true, jsx: true });
      case "zig":
      default:
        return [];
    }
  }

  let host: HTMLDivElement;
  let view: EditorView;
  const langComp = new Compartment();
  let applying = false;

  onMount(() => {
    view = new EditorView({
      parent: host,
      state: EditorState.create({
        doc: value,
        extensions: [
          basicSetup,
          langComp.of(extFor(lang)),
          EditorView.updateListener.of((u) => {
            if (u.docChanged) {
              applying = true;
              value = u.state.doc.toString();
              applying = false;
            }
          }),
        ],
      }),
    });
    onReady?.(view);
    return () => view.destroy();
  });

  $effect(() => {
    if (!view || applying) return;
    const current = view.state.doc.toString();
    if (current !== value) {
      view.dispatch({ changes: { from: 0, to: current.length, insert: value } });
    }
  });

  $effect(() => {
    if (!view) return;
    view.dispatch({ effects: langComp.reconfigure(extFor(lang)) });
  });
</script>

<div class="editor" bind:this={host}></div>

<style>
  .editor :global(.cm-editor) {
    height: 100%;
    font-size: 14px;
  }
  .editor {
    height: 100%;
    min-height: 300px;
    border: 1px solid #ddd;
  }
</style>
